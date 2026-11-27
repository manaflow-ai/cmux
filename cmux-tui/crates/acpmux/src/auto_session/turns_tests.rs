use std::time::Duration;

use super::*;

#[tokio::test]
async fn a_chat_has_one_turn_and_another_chat_does_not_wait_for_it() {
    let turns = Arc::new(Turns::default());
    let first = turns.take("a").await;
    // Another chat goes at once.
    let _other = turns.take("b").await;
    let (done, mut heard) = tokio::sync::mpsc::unbounded_channel();
    let waiting = turns.clone();
    let second = tokio::spawn(async move {
        let _turn = waiting.take("a").await;
        let _ = done.send(());
    });
    let early = tokio::time::timeout(Duration::from_millis(200), heard.recv()).await;
    assert!(early.is_err(), "the second took the turn while the first held it");
    drop(first);
    tokio::time::timeout(Duration::from_secs(10), heard.recv())
        .await
        .expect("the second goes once the first is done");
    second.await.unwrap();
}
