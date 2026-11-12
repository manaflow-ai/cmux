//! The app's Cloud carrier (`cmux-mobile-carrier`): one session per Cloud
//! machine, dialed with the person's own access token and this phone's Noise
//! key, and its `cmux.protocol/2` line streams for the app's daemon client.

use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use cmux_mobile_carrier::{
    CarrierError, CarrierSession, CarrierStream, NoiseIdentity, Platform, TokenSource,
};
use zeroize::Zeroizing;

use crate::{CmuxMobileError, UNAUTHORIZED, on_runtime};

/// The code of [`CmuxMobileError::Refused`] when the machine's daemon is not
/// the pinned one or refused this phone's grant (or its mux stream).
pub const CARRIER_HANDSHAKE: &str = "carrier.handshake";

/// The code of [`CmuxMobileError::Refused`] when the platform's carrier answer
/// was not usable (malformed, or no grant). Retryable: a later ask may pass.
pub const CARRIER_ANSWER: &str = "carrier.answer";

/// Where a carrier gets the person's access token: the app's own sign-in,
/// asked at every platform ask (a grant for a dial, a ticket for a resume),
/// so a session that outlives one token resumes with the next.
/// `force_refresh` comes once after the platform refused a token; answer with
/// [`CmuxMobileError::Refused`] code `unauthorized` when signed out.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait CloudTokenSource: Send + Sync {
    async fn access_token(&self, force_refresh: bool) -> Result<String, CmuxMobileError>;
}

/// The app's [`CloudTokenSource`] as the carrier's [`TokenSource`].
struct AppTokens(Arc<dyn CloudTokenSource>);

#[async_trait::async_trait]
impl TokenSource for AppTokens {
    async fn access_token(&self, force_refresh: bool) -> Result<Zeroizing<String>, CarrierError> {
        match self.0.access_token(force_refresh).await {
            Ok(token) => Ok(Zeroizing::new(token)),
            Err(CmuxMobileError::Refused { code, .. }) if code == UNAUTHORIZED => {
                Err(CarrierError::Unauthorized)
            }
            Err(error) => Err(CarrierError::Transport {
                step: "token",
                detail: format!("the app has no access token: {error}"),
                retryable: true,
            }),
        }
    }
}

/// [`on_runtime`] whose spawned work stops when the caller stops waiting (a
/// Swift task cancelled, a link no longer wanted): a dial never runs on to its
/// deadline minting grants for nobody. What the dial built is closed by its
/// own drop guard.
async fn on_runtime_until_dropped<F, T>(future: F) -> Result<T, CmuxMobileError>
where
    F: std::future::Future<Output = Result<T, CmuxMobileError>> + Send + 'static,
    T: Send + 'static,
{
    struct AbortOnDrop(tokio::task::AbortHandle);
    impl Drop for AbortOnDrop {
        fn drop(&mut self) {
            self.0.abort();
        }
    }
    let task = crate::runtime().spawn(future);
    let _abort = AbortOnDrop(task.abort_handle());
    match task.await {
        Ok(value) => value,
        Err(error) if error.is_panic() => std::panic::resume_unwind(error.into_panic()),
        Err(_) => Err(CarrierError::Closed.into()),
    }
}

impl From<CarrierError> for CmuxMobileError {
    fn from(error: CarrierError) -> Self {
        match error {
            CarrierError::Unauthorized => {
                Self::Refused { code: UNAUTHORIZED.into(), message: error.to_string() }
            }
            CarrierError::Refused { code, message, .. } => Self::Refused { code, message },
            CarrierError::Handshake(message) => Self::Refused { code: CARRIER_HANDSHAKE.into(), message },
            CarrierError::Transport { .. } => Self::Transport { message: error.to_string() },
            CarrierError::Invalid(message) => Self::InvalidArgument { message },
            CarrierError::Answer(message) => Self::Refused { code: CARRIER_ANSWER.into(), message },
            CarrierError::Closed => Self::Closed { message: error.to_string() },
        }
    }
}

/// A foreign callback that failed in a way the bindings could not map (a
/// Swift error that is not a `CmuxMobileError`).
impl From<uniffi::UnexpectedUniFFICallbackError> for CmuxMobileError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Transport { message: format!("the app's callback failed: {}", error.reason) }
    }
}

/// A new Noise private key for this phone's carriers (the app keeps it in
/// its Keychain).
#[uniffi::export]
pub fn cloud_carrier_new_key() -> Result<Vec<u8>, CmuxMobileError> {
    Ok(cmux_mobile_carrier::generate_private_key()?.to_vec())
}

/// One Cloud machine's carrier.
///
/// The live session sits in a slot behind a short, synchronous lock: a dial
/// runs outside it (one at a time, behind `dialing`) and installs its session
/// at the end, so [`CloudCarrier::is_connected`], [`CloudCarrier::wait_closed`]
/// and [`CloudCarrier::close`] never wait out a dial. `close` is final: it ends
/// the live session, cancels a dial in flight (its session is closed, never
/// installed) and refuses later dials. A dropped carrier closes its session.
#[derive(uniffi::Object)]
pub struct CloudCarrier {
    platform: Arc<Platform>,
    identity: NoiseIdentity,
    device_name: String,
    slot: Mutex<Slot>,
    /// One dial at a time.
    dialing: tokio::sync::Mutex<()>,
    /// Set by `close`: wakes a dial in flight and every `wait_closed`.
    closing: tokio::sync::watch::Sender<bool>,
}

#[derive(Default)]
struct Slot {
    session: Option<Arc<CarrierSession>>,
    closed: bool,
}

impl CloudCarrier {
    fn slot(&self) -> std::sync::MutexGuard<'_, Slot> {
        self.slot.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The live session, if any (`Closed` once the carrier was closed).
    fn live(&self) -> Result<Option<Arc<CarrierSession>>, CarrierError> {
        let slot = self.slot();
        if slot.closed {
            return Err(CarrierError::Closed);
        }
        Ok(slot.session.clone().filter(|session| !session.is_closed()))
    }

    async fn dial(self: Arc<Self>, deadline_ms: u32) -> Result<(), CmuxMobileError> {
        if self.live()?.is_some() {
            return Ok(());
        }
        let _one = self.dialing.lock().await;
        // Another dial may have finished while this one waited.
        if self.live()?.is_some() {
            return Ok(());
        }
        let deadline = tokio::time::Instant::now() + Duration::from_millis(u64::from(deadline_ms));
        let mut closing = self.closing.subscribe();
        let dialed = tokio::select! {
            dialed = CarrierSession::dial(
                self.platform.clone(),
                self.identity.clone(),
                self.device_name.clone(),
                deadline,
            ) => dialed?,
            _ = closing.wait_for(|closed| *closed) => return Err(CarrierError::Closed.into()),
        };
        let dialed = Arc::new(dialed);
        let (old, installed) = {
            let mut slot = self.slot();
            if slot.closed { (None, false) } else { (slot.session.replace(dialed.clone()), true) }
        };
        if let Some(old) = old {
            old.close().await;
        }
        if !installed {
            // Closed while it dialed: nothing may keep this session.
            dialed.close().await;
            return Err(CarrierError::Closed.into());
        }
        Ok(())
    }
}

#[uniffi::export]
impl CloudCarrier {
    /// `api_base` is the Cloud API (`https://cloud-api.cmux.dev`), `team_id`
    /// the team to send as `x-cmux-team` (nil: the account's default scope),
    /// `machine_id` a `vm_…` id, `tokens` the app's sign-in,
    /// `noise_private_key` this phone's 32-byte key ([`cloud_carrier_new_key`]).
    #[uniffi::constructor]
    pub fn new(
        api_base: String,
        team_id: Option<String>,
        machine_id: String,
        tokens: Arc<dyn CloudTokenSource>,
        noise_private_key: Vec<u8>,
        device_name: String,
    ) -> Result<Arc<Self>, CmuxMobileError> {
        let private: [u8; 32] = noise_private_key.try_into().map_err(|_| {
            CmuxMobileError::InvalidArgument { message: "the Noise key is not 32 bytes".into() }
        })?;
        let platform = Platform::with_tokens(&api_base, team_id, &machine_id, Arc::new(AppTokens(tokens)))?;
        Ok(Arc::new(Self {
            platform: Arc::new(platform),
            identity: NoiseIdentity::from_private(private),
            device_name,
            slot: Mutex::new(Slot::default()),
            dialing: tokio::sync::Mutex::new(()),
            closing: tokio::sync::watch::channel(false).0,
        }))
    }

    /// Dial the machine unless a live session is up, within `deadline_ms`.
    /// `Closed` once [`CloudCarrier::close`] ran (also for a dial it cut
    /// short). A caller that stops waiting stops the dial.
    pub async fn connect(self: Arc<Self>, deadline_ms: u32) -> Result<(), CmuxMobileError> {
        on_runtime_until_dropped(async move { self.dial(deadline_ms).await }).await
    }

    /// One more daemon line stream on the live session (`Closed` when there is
    /// none: the app dials a new carrier).
    pub async fn open_stream(self: Arc<Self>) -> Result<Arc<CloudCarrierStream>, CmuxMobileError> {
        on_runtime(async move {
            let session = self.live()?.ok_or(CarrierError::Closed)?;
            let stream = session.open_stream().await?;
            Ok(Arc::new(CloudCarrierStream { inner: Arc::new(stream) }))
        })
        .await
    }

    /// Whether a live session is up (never waits for a dial).
    pub async fn is_connected(&self) -> bool {
        matches!(self.live(), Ok(Some(_)))
    }

    /// Resolves once the live session ends or the carrier is closed (at once
    /// when there is no live session), so the app drops its link promptly.
    pub async fn wait_closed(self: Arc<Self>) {
        on_runtime(async move {
            let Ok(Some(session)) = self.live() else { return };
            let mut closing = self.closing.subscribe();
            tokio::select! {
                () = session.closed() => {}
                _ = closing.wait_for(|closed| *closed) => {}
            }
        })
        .await;
    }

    /// Ends the carrier for good: its session closes, a dial in flight stops.
    pub async fn close(self: Arc<Self>) {
        on_runtime(async move {
            let session = {
                let mut slot = self.slot();
                slot.closed = true;
                slot.session.take()
            };
            self.closing.send_replace(true);
            if let Some(session) = session {
                session.close().await;
            }
        })
        .await;
    }
}

impl Drop for CloudCarrier {
    fn drop(&mut self) {
        let session = self.slot.get_mut().unwrap_or_else(PoisonError::into_inner).session.take();
        self.closing.send_replace(true);
        if let Some(session) = session {
            crate::runtime().spawn(async move { session.close().await });
        }
    }
}

/// One daemon line stream on a Cloud carrier.
#[derive(uniffi::Object)]
pub struct CloudCarrierStream {
    inner: Arc<CarrierStream>,
}

#[uniffi::export]
impl CloudCarrierStream {
    pub async fn send(&self, data: Vec<u8>) -> Result<(), CmuxMobileError> {
        let inner = self.inner.clone();
        on_runtime(async move { inner.send(&data).await }).await?;
        Ok(())
    }

    /// The next bytes from the daemon, or None once the stream ended.
    pub async fn recv(&self) -> Option<Vec<u8>> {
        let inner = self.inner.clone();
        on_runtime(async move { inner.receive().await }).await
    }

    pub async fn close(&self) {
        let inner = self.inner.clone();
        on_runtime(async move { inner.close().await }).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MACHINE: &str = "vm_0123456789abcdefghij";

    struct Tokens;

    #[async_trait::async_trait]
    impl CloudTokenSource for Tokens {
        async fn access_token(&self, _force_refresh: bool) -> Result<String, CmuxMobileError> {
            Ok("token".into())
        }
    }

    fn carrier(base: &str) -> Arc<CloudCarrier> {
        CloudCarrier::new(base.into(), None, MACHINE.into(), Arc::new(Tokens), vec![7; 32], "iPhone".into())
            .unwrap()
    }

    /// A platform that accepts the ask and never answers: a dial waits on it.
    async fn silent_platform() -> (String, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            let mut held = Vec::new();
            while let Ok((stream, _)) = listener.accept().await {
                held.push(stream);
            }
        });
        (base, task)
    }

    #[tokio::test]
    async fn close_cuts_a_dial_short_and_is_final() {
        let (base, server) = silent_platform().await;
        let carrier = carrier(&base);
        let dialing = tokio::spawn(carrier.clone().connect(20_000));
        // The dial is waiting on the platform; probes and close never wait for it.
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(!carrier.is_connected().await);
        let started = std::time::Instant::now();
        carrier.clone().close().await;
        let dialed =
            tokio::time::timeout(Duration::from_secs(5), dialing).await.expect("the dial ended").unwrap();
        assert!(matches!(dialed, Err(CmuxMobileError::Closed { .. })), "{dialed:?}");
        assert!(started.elapsed() < Duration::from_secs(5));
        // Closed for good: no later dial, stream or session.
        assert!(matches!(carrier.clone().connect(1_000).await, Err(CmuxMobileError::Closed { .. })));
        assert!(matches!(carrier.clone().open_stream().await, Err(CmuxMobileError::Closed { .. })));
        assert!(!carrier.is_connected().await);
        server.abort();
    }

    #[tokio::test]
    async fn wait_closed_returns_at_once_without_a_session() {
        let carrier = carrier("http://127.0.0.1:9");
        tokio::time::timeout(Duration::from_secs(2), carrier.clone().wait_closed())
            .await
            .expect("no session to wait on");
        carrier.clone().close().await;
        tokio::time::timeout(Duration::from_secs(2), carrier.wait_closed()).await.expect("closed");
    }

    #[tokio::test]
    async fn a_dial_its_caller_drops_stops_asking_the_platform() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let asks = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counted = asks.clone();
        // Accepts each ask and closes it at once: a transport failure the dial retries.
        let server = tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                drop(stream);
            }
        });
        let carrier = carrier(&base);
        let dial = carrier.clone().connect(30_000);
        assert!(tokio::time::timeout(Duration::from_millis(800), dial).await.is_err(), "still dialing");
        // The caller gave up (the timeout dropped its future): the dial stops.
        tokio::time::sleep(Duration::from_millis(300)).await;
        let after_drop = asks.load(std::sync::atomic::Ordering::SeqCst);
        tokio::time::sleep(Duration::from_millis(2_500)).await;
        assert_eq!(
            asks.load(std::sync::atomic::Ordering::SeqCst),
            after_drop,
            "no ask after the caller left"
        );
        assert!(after_drop >= 1);
        server.abort();
    }

    #[test]
    fn an_unusable_answer_is_retryable_and_keeps_its_code() {
        assert!(CarrierError::Answer("no grant".into()).retryable());
        let error: CmuxMobileError = CarrierError::Answer("no grant".into()).into();
        assert!(matches!(error, CmuxMobileError::Refused { ref code, .. } if code == CARRIER_ANSWER));
    }

    #[tokio::test]
    async fn no_daemon_key_keeps_its_code() {
        let error: CmuxMobileError = CarrierError::Refused {
            code: cmux_mobile_carrier::NO_DAEMON_KEY.into(),
            message: "none".into(),
            retryable: true,
        }
        .into();
        assert!(
            matches!(error, CmuxMobileError::Refused { ref code, .. } if code == "carrier.no_daemon_key")
        );
    }
}
