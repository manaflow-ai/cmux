//! A mailbox frame the backend sends right after `hello`, before any caller
//! subscribed to the client's events, is still read (PR B review, blocking 2).

use cmux_mobile_link::signaling::{MailboxItem, SignalingClient};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};

#[tokio::test]
async fn a_mailbox_frame_sent_right_after_hello_is_never_lost() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let device = "6f1c2a7e-0b1d-4c55-9a43-2d8e5b7f3c10";
    let client = SignalingClient::connect(&server.base_url, "user:u1", "t1", device).await.unwrap();
    // The backend sends it at once; nobody listens to `events()` yet.
    let frame =
        serde_json::json!({"type": "mailbox", "items": [{"id": "r1", "from": "p", "sealed": "AQ", "at": 5}]});
    assert!(server.send_to_device(device, &frame));
    // A later subscriber of the broadcast events would have missed it; the queue keeps it.
    let items = tokio::time::timeout(std::time::Duration::from_secs(5), client.next_mailbox()).await.unwrap();
    assert_eq!(
        items,
        Some(vec![MailboxItem { id: "r1".into(), from: "p".into(), sealed: "AQ".into(), at: Some(5) }])
    );
}
