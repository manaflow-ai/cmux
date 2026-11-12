//! The app's Cloud carrier (`cmux-mobile-carrier`): one session per Cloud
//! machine, dialed with the person's own access token and this phone's Noise
//! key, and its `cmux.protocol/2` line streams for the app's daemon client.

use std::sync::Arc;
use std::time::Duration;

use cmux_mobile_carrier::{CarrierError, CarrierSession, CarrierStream, NoiseIdentity, Platform};

use crate::{CmuxMobileError, UNAUTHORIZED, on_runtime};

/// The code of [`CmuxMobileError::Refused`] when the machine's daemon is not
/// the pinned one or refused this phone's grant.
pub const CARRIER_HANDSHAKE: &str = "carrier.handshake";

impl From<CarrierError> for CmuxMobileError {
    fn from(error: CarrierError) -> Self {
        match error {
            CarrierError::Unauthorized => {
                Self::Refused { code: UNAUTHORIZED.into(), message: error.to_string() }
            }
            CarrierError::Refused { code, message, .. } => Self::Refused { code, message },
            CarrierError::Handshake(message) => {
                Self::Refused { code: CARRIER_HANDSHAKE.into(), message }
            }
            CarrierError::Transport { .. } => Self::Transport { message: error.to_string() },
            CarrierError::Invalid(message) => Self::InvalidArgument { message },
            CarrierError::Closed => Self::Closed { message: error.to_string() },
        }
    }
}

/// A new Noise private key for this phone's carriers (the app keeps it in
/// its Keychain).
#[uniffi::export]
pub fn cloud_carrier_new_key() -> Result<Vec<u8>, CmuxMobileError> {
    Ok(cmux_mobile_carrier::generate_private_key()?.to_vec())
}

/// One Cloud machine's carrier.
#[derive(uniffi::Object)]
pub struct CloudCarrier {
    platform: Arc<Platform>,
    identity: NoiseIdentity,
    device_name: String,
    session: tokio::sync::Mutex<Option<Arc<CarrierSession>>>,
}

#[uniffi::export]
impl CloudCarrier {
    /// `api_base` is the Cloud API (`https://cloud-api.cmux.dev`), `team_id`
    /// the active team (sent as `x-cmux-team`), `machine_id` a `vm_…` id,
    /// `noise_private_key` this phone's 32-byte key ([`cloud_carrier_new_key`]).
    #[uniffi::constructor]
    pub fn new(
        api_base: String,
        team_id: Option<String>,
        machine_id: String,
        access_token: String,
        noise_private_key: Vec<u8>,
        device_name: String,
    ) -> Result<Arc<Self>, CmuxMobileError> {
        let private: [u8; 32] = noise_private_key.try_into().map_err(|_| {
            CmuxMobileError::InvalidArgument { message: "the Noise key is not 32 bytes".into() }
        })?;
        let platform = Platform::new(&api_base, team_id, &machine_id, access_token)?;
        Ok(Arc::new(Self {
            platform: Arc::new(platform),
            identity: NoiseIdentity::from_private(private),
            device_name,
            session: tokio::sync::Mutex::new(None),
        }))
    }

    /// Replace the access token the carrier asks the platform with (tickets
    /// for a resume, grants for a fresh dial).
    pub fn set_access_token(&self, access_token: String) {
        self.platform.set_token(access_token);
    }

    /// Dial the machine unless a live session is up, within `deadline_ms`.
    pub async fn connect(self: Arc<Self>, deadline_ms: u32) -> Result<(), CmuxMobileError> {
        on_runtime(async move {
            let mut session = self.session.lock().await;
            if session.as_ref().is_some_and(|live| !live.is_closed()) {
                return Ok(());
            }
            if let Some(old) = session.take() {
                old.close().await;
            }
            let deadline =
                tokio::time::Instant::now() + Duration::from_millis(u64::from(deadline_ms));
            let dialed = CarrierSession::dial(
                self.platform.clone(),
                self.identity.clone(),
                self.device_name.clone(),
                deadline,
            )
            .await?;
            *session = Some(Arc::new(dialed));
            Ok(())
        })
        .await
    }

    /// One more daemon line stream on the live session (`Closed` when there is
    /// none: the app dials again with [`CloudCarrier::connect`]).
    pub async fn open_stream(self: Arc<Self>) -> Result<Arc<CloudCarrierStream>, CmuxMobileError> {
        on_runtime(async move {
            let session = self.session.lock().await.clone();
            let session = session.filter(|live| !live.is_closed()).ok_or(CarrierError::Closed)?;
            let stream = session.open_stream().await?;
            Ok(Arc::new(CloudCarrierStream { inner: Arc::new(stream) }))
        })
        .await
    }

    /// Whether a live session is up.
    pub async fn is_connected(&self) -> bool {
        self.session.lock().await.as_ref().is_some_and(|live| !live.is_closed())
    }

    pub async fn close(self: Arc<Self>) {
        on_runtime(async move {
            if let Some(session) = self.session.lock().await.take() {
                session.close().await;
            }
        })
        .await;
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
