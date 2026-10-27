//! Panic injection for a link's reader: its end runs on an unwind too, so the link
//! reports closed and no query waits for a reply that cannot come.

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use super::*;

#[tokio::test]
async fn a_reader_that_panics_closes_its_link() {
    let closed = Arc::new(AtomicBool::new(false));
    let queries: Queries = Arc::default();
    let (reply_tx, reply) = oneshot::channel();
    queries.lock_or_recover().insert(1, reply_tx);
    {
        let end = ReaderEnd { closed: closed.clone(), queries: queries.clone() };
        crate::supervised::spawn_scoped(async move {
            let _end = end;
            panic!("injected in the reader");
        });
    }
    let answered = tokio::time::timeout(Duration::from_secs(5), reply).await;
    assert!(matches!(answered, Ok(Err(_))), "the waiting query was dropped");
    assert!(closed.load(Ordering::SeqCst));
    assert!(queries.lock_or_recover().is_empty());
}
