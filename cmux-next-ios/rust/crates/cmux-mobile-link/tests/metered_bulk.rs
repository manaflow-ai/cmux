//! Scoreboard row W5, "metered cell | iOS→Mac | bulk bytes sent without consent": a 4 MiB
//! upload from a phone whose network is cellular, measured at the Mac.
//!
//! Its own test binary: the cellular flag and the consent are process-wide, as they are in the app.

use std::time::Duration;

use bytes::Bytes;
use cmux_mobile_link::dial::wireguard::set_cellular_path;
use cmux_mobile_link::{ChannelEvent, Lane, Link, LinkConfig, Role};

const UPLOAD: usize = 4 * 1024 * 1024;
/// How long the Mac counts what arrives while the phone is metered without consent.
const WINDOW: Duration = Duration::from_secs(2);

/// The tests share the process-wide flags: one at a time.
static SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

fn pair() -> (Link, Link) {
    let (a, b) = tokio::io::duplex(256 * 1024);
    (
        Link::new(a, Role::Phone, LinkConfig::default(), None),
        Link::new(b, Role::Mac, LinkConfig::default(), None),
    )
}

/// The Mac: echoes `chat` and `keys`, counts `upload` bytes into `received`.
fn serve(mac: Link, received: tokio::sync::watch::Sender<usize>) -> tokio::task::JoinHandle<Link> {
    tokio::spawn(async move {
        while let Some(mut incoming) = mac.accept().await {
            let received = received.clone();
            tokio::spawn(async move {
                let upload = incoming.service == "upload";
                while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                    if upload {
                        received.send_modify(|n| *n += bytes.len());
                    } else {
                        let _ = incoming.channel.send(bytes).await;
                    }
                }
            });
        }
        mac
    })
}

async fn echo(channel: &mut cmux_mobile_link::Channel, text: &'static [u8]) -> Duration {
    let started = tokio::time::Instant::now();
    channel.send(Bytes::from_static(text)).await.unwrap();
    let mut got = Vec::new();
    while got.len() < text.len() {
        match tokio::time::timeout(Duration::from_secs(2), channel.recv()).await {
            Ok(Some(ChannelEvent::Data(bytes))) => got.extend_from_slice(&bytes),
            other => panic!("no echo: {other:?}"),
        }
    }
    assert_eq!(got, text);
    started.elapsed()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn metered_upload_waits_for_consent_while_chat_and_keys_flow() {
    let _serial = SERIAL.lock().await;
    set_cellular_path(true);
    let (phone, mac) = pair();
    let (received_tx, mut received) = tokio::sync::watch::channel(0usize);
    let _server = serve(mac, received_tx);

    let mut chat = phone.open("chat", serde_json::json!({})).await.unwrap();
    let mut keys = phone.open_on("keys", serde_json::json!({}), Lane::Input).await.unwrap();
    let upload = phone.open("upload", serde_json::json!({"name": "a.bin", "size": UPLOAD})).await.unwrap();
    let uploading = tokio::spawn(async move {
        let sent = upload.send(Bytes::from(vec![0xA5u8; UPLOAD])).await;
        (upload, sent)
    });

    // Chat and keystrokes go while the upload is there.
    tokio::time::sleep(Duration::from_millis(200)).await;
    let chat_rtt = echo(&mut chat, b"small chat message").await;
    let key_rtt = echo(&mut keys, b"k").await;
    tokio::time::sleep(WINDOW).await;
    let unconsented = *received.borrow();
    eprintln!(
        "W5 metered cell: bulk bytes sent without consent = {unconsented} of {UPLOAD}; \
         chat echo {chat_rtt:?}, key echo {key_rtt:?}"
    );

    gate::after_window(&phone, unconsented, &mut received, uploading).await;
    set_cellular_path(false);
}

/// The gate: nothing went without consent; the yes releases all of it.
mod gate {
    use super::*;
    use cmux_mobile_link::metered;

    pub async fn after_window(
        phone: &Link,
        unconsented: usize,
        received: &mut tokio::sync::watch::Receiver<usize>,
        uploading: tokio::task::JoinHandle<(
            cmux_mobile_link::Channel,
            Result<(), cmux_mobile_link::LinkError>,
        )>,
    ) {
        assert_eq!(unconsented, 0, "no bulk byte goes on cell without consent");
        assert_eq!(phone.metered_bulk_sent().unconsented, 0);
        let state = metered::state();
        assert!(state.metered && !state.consent, "{state:?}");
        assert!(state.waiting_bytes > 0, "the app can see what waits: {state:?}");
        assert!(metered::subscribe().borrow().waiting);
        assert!(!uploading.is_finished(), "back-pressure: the sender waits, no error");
        eprintln!("after: {unconsented} bytes went; {} bytes waiting for consent", state.waiting_bytes);

        metered::set_metered_bulk_consent(true);
        tokio::time::timeout(Duration::from_secs(10), received.wait_for(|n| *n == UPLOAD))
            .await
            .expect("the yes releases the whole upload")
            .unwrap();
        let (_upload, sent) = uploading.await.unwrap();
        sent.unwrap();
        let counted = phone.metered_bulk_sent();
        assert_eq!(counted.unconsented, 0);
        assert_eq!(counted.consented, UPLOAD as u64);
        assert_eq!(metered::state().waiting_bytes, 0);
        eprintln!("after consent: {} bytes went with consent", counted.consented);
    }
}

/// Leaving cell releases what waits, and forgets the yes; a cancelled held upload sends nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn leaving_cell_releases_and_a_cancel_sends_nothing() {
    use cmux_mobile_link::metered;
    let _serial = SERIAL.lock().await;
    // Low Data Mode on Wi-Fi is metered too.
    set_cellular_path(false);
    metered::set_constrained_path(true);
    let (phone, mac) = pair();
    let (received_tx, mut received) = tokio::sync::watch::channel(0usize);
    let _server = serve(mac, received_tx);

    // A cancel while held: the close goes alone.
    let cancelled = phone.open("upload", serde_json::json!({})).await.unwrap();
    let (cancel_tx, cancel_rx) = cancelled.split();
    let held = tokio::spawn(async move {
        let _ = cancel_tx.send(Bytes::from(vec![1u8; 64 * 1024])).await;
        cancel_tx
    });
    tokio::time::sleep(Duration::from_millis(300)).await;
    held.await.unwrap().close("cancelled", "cancelled").await;
    drop(cancel_rx);
    assert_eq!(metered::state().waiting_bytes, 0, "the cancel dropped the held bytes");

    let upload = phone.open("upload", serde_json::json!({})).await.unwrap();
    let uploading = tokio::spawn(async move { upload.send(Bytes::from(vec![2u8; 512 * 1024])).await });
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(*received.borrow(), 0);
    metered::set_metered_bulk_consent(true);
    assert!(metered::state().consent);
    metered::set_metered_bulk_consent(false);

    // Off the metered network: it goes by itself, and the consent is not kept.
    metered::set_constrained_path(false);
    tokio::time::timeout(Duration::from_secs(10), received.wait_for(|n| *n == 512 * 1024))
        .await
        .expect("leaving the metered network releases the upload")
        .unwrap();
    uploading.await.unwrap().unwrap();
    metered::set_metered_bulk_consent(true);
    assert!(!metered::state().consent, "a yes off a metered network is not kept");
    metered::set_constrained_path(true);
    assert!(!metered::bulk_allowed(), "back on a metered network, it asks again");
    metered::set_constrained_path(false);
    assert_eq!(phone.metered_bulk_sent().unconsented, 0);
}
