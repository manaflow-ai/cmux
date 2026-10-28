//! Panic injection for the client's read loop: a reader that panics closes the
//! connection as its end of file does, so an in-flight call fails at once.

use std::sync::atomic::AtomicBool;
use std::time::Duration;

use super::*;

#[tokio::test]
async fn a_read_loop_panic_fails_the_in_flight_call() {
    let closed = Arc::new(AtomicBool::new(false));
    let pending: Pending = Arc::default();
    let (notif, mut notifications) = mpsc::channel(4);
    let notif_tx = Arc::new(Mutex::new(notif));
    let (answer_tx, answer) = oneshot::channel();
    pending.lock().await.insert("1".to_owned(), answer_tx);
    {
        let (closed, pending, notif_tx) = (closed.clone(), pending.clone(), notif_tx.clone());
        crate::supervised::spawn_scoped(async move {
            let read = async { panic!("injected in the read loop") };
            read_then_close(read, &closed, &pending, &notif_tx).await;
        });
    }
    let answered = tokio::time::timeout(Duration::from_secs(5), answer)
        .await
        .expect("the call fails within 5 s")
        .expect("an answer, not a dropped sender");
    let error = answered.expect_err("the connection closed");
    assert_eq!(error.message, "daemon connection closed");
    assert!(closed.load(Ordering::SeqCst));
    let goodbye = notifications.recv().await.expect("the goodbye");
    assert!(
        matches!(&goodbye, Message::Notification { method: m, .. } if m == method::MUX_DISCONNECTED),
        "{goodbye:?}"
    );
}
