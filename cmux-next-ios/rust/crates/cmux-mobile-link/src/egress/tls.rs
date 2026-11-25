//! Which certificates the link's own TLS trusts: the OS trust store.
//!
//! The signaling WebSocket, the HTTP API and TURN over TLS verify their
//! server against the operating system's trust store (`rustls-platform-verifier`:
//! the Security framework on iOS and macOS, the system's certificate bundle
//! elsewhere), not only the public web PKI bundled in the app. A company network
//! that inspects TLS re-signs every certificate with its own root, which an MDM
//! profile (or the person, in Settings > General > About > Certificate Trust
//! Settings) installed and trusted; URLSession and Safari trust it, and before
//! this so did everything in the app but the link.
//!
//! This widens nothing the link relies on. WireGuard authenticates and encrypts
//! every byte between the phone and the Mac, and the phone pins the Mac's
//! identity key (SECURITY.md "Who the peer is"), so a TLS proxy between this
//! device and the TURN server or the backend sees ciphertext, addresses and the
//! bearer token, exactly what URLSession already hands it for the app's API
//! calls. A certificate the OS does not trust still fails the connection.

use std::fmt;
use std::sync::{Arc, OnceLock};

use rustls::client::WebPkiServerVerifier;
use rustls::client::danger::ServerCertVerifier;
use rustls::crypto::CryptoProvider;
use rustls::pki_types::CertificateDer;
use rustls::{ClientConfig, RootCertStore};

/// The roots a connection trusts.
#[derive(Clone, Default)]
pub enum TlsTrust {
    /// The OS trust store, with whatever roots the person or an MDM profile
    /// added. Where no platform verifier can be built (a Linux box without a
    /// certificate bundle), the bundled web PKI.
    #[default]
    System,
    /// The OS trust store plus these roots, as if the OS trusted them too
    /// (tests: a company root an MDM profile would have installed).
    SystemWith(Arc<[CertificateDer<'static>]>),
    /// These roots and nothing else (tests: a self-signed test server).
    Only(Arc<RootCertStore>),
    /// The web PKI bundled in the app (webpki-roots) and nothing else: what
    /// the link trusted before it read the OS store (tests compare against it).
    Bundled,
}

impl fmt::Debug for TlsTrust {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::System => f.write_str("System"),
            Self::SystemWith(roots) => write!(f, "SystemWith({} roots)", roots.len()),
            Self::Only(roots) => write!(f, "Only({} roots)", roots.len()),
            Self::Bundled => f.write_str("Bundled"),
        }
    }
}

fn provider() -> Arc<CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

/// The bundled web PKI (Mozilla's roots, compiled in).
fn bundled_roots() -> RootCertStore {
    RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() }
}

fn webpki_verifier(roots: RootCertStore) -> Result<Arc<dyn ServerCertVerifier>, String> {
    let verifier = WebPkiServerVerifier::builder_with_provider(Arc::new(roots), provider())
        .build()
        .map_err(|error| error.to_string())?;
    Ok(verifier)
}

/// The OS verifier, with `extra` roots beside the store's own. A platform with
/// no usable store (no certificate bundle) gets the bundled web PKI plus
/// `extra` instead, so the link never ends up trusting nothing.
fn system_verifier(extra: &[CertificateDer<'static>]) -> Result<Arc<dyn ServerCertVerifier>, String> {
    let built = if extra.is_empty() {
        rustls_platform_verifier::Verifier::new(provider())
    } else {
        rustls_platform_verifier::Verifier::new_with_extra_roots(extra.iter().cloned(), provider())
    };
    match built {
        Ok(verifier) => Ok(Arc::new(verifier)),
        Err(error) => {
            tracing::warn!(%error, "no OS trust store here; TLS verifies against the bundled web PKI");
            let mut roots = bundled_roots();
            for root in extra {
                roots.add(root.clone()).map_err(|error| error.to_string())?;
            }
            webpki_verifier(roots)
        }
    }
}

fn with_verifier(verifier: Arc<dyn ServerCertVerifier>) -> Result<ClientConfig, String> {
    Ok(ClientConfig::builder_with_provider(provider())
        .with_safe_default_protocol_versions()
        .map_err(|error| error.to_string())?
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_no_client_auth())
}

fn build(trust: &TlsTrust) -> Result<ClientConfig, String> {
    match trust {
        TlsTrust::System => with_verifier(system_verifier(&[])?),
        TlsTrust::SystemWith(extra) => with_verifier(system_verifier(extra)?),
        TlsTrust::Only(roots) => Ok(ClientConfig::builder_with_provider(provider())
            .with_safe_default_protocol_versions()
            .map_err(|error| error.to_string())?
            .with_root_certificates(Arc::clone(roots))
            .with_no_client_auth()),
        TlsTrust::Bundled => with_verifier(webpki_verifier(bundled_roots())?),
    }
}

/// The TLS client configuration for `trust`. The OS one is built once per
/// process (the verifier asks the OS on every handshake, so a root installed
/// later still counts on Apple platforms).
pub fn client_config(trust: &TlsTrust) -> Result<Arc<ClientConfig>, String> {
    if matches!(trust, TlsTrust::System) {
        static SYSTEM: OnceLock<Result<Arc<ClientConfig>, String>> = OnceLock::new();
        return SYSTEM.get_or_init(|| build(trust).map(Arc::new)).clone();
    }
    build(trust).map(Arc::new)
}
