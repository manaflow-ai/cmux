use super::*;
use crate::conn::SubscriptionControl;
use acpmux_book::index::{Summary, SummaryIndex};
use std::time::Duration;

struct PausedSink;

impl OfferSink for PausedSink {
    fn offer(&self, _: &str, _: Frame, _: Cursor) -> Offer {
        Offer::NotFed
    }
    fn fail(&self, _: &str) {
        panic!("replay failed");
    }
    fn control(&self, _: &str) -> Option<Arc<SubscriptionControl>> {
        None
    }
    fn metrics(&self) -> Arc<ConnectionMetrics> {
        Arc::default()
    }
}

#[tokio::test]
async fn paused_mid_replay_releases_the_snapshot_before_credit_returns() {
    for resume_pending in [false, true] {
        let (hub, mut writer) = Hub::new(SummaryIndex::new());
        for n in 0..1500 {
            let mut row = Summary::new(format!("chat-{n}"));
            row.title = "r".repeat(240);
            writer.apply(row).unwrap();
        }
        let hub = Arc::new(hub);
        let mut sub = Sub::new("paused", "list");
        sub.cursor = Some(Cursor(0));
        sub.edition = Some(0);
        let delivery = open(&hub, &sub).unwrap();
        assert!(matches!(delivery.mode, Mode::Replay(_)));
        let weak = delivery.receiver.replay_snapshot_probe().unwrap();
        delivery.receiver.reposition(delivery.cursor.0);
        let (credit, resume) = watch::channel(Cursor(0));
        if resume_pending {
            credit.send_replace(delivery.cursor);
        }
        let held = Arc::new(Held::default());
        let task = tokio::spawn(pump(
            hub,
            sub,
            Arc::new(PausedSink),
            delivery.receiver,
            delivery.mode,
            resume,
            held.clone(),
        ));
        tokio::time::timeout(Duration::from_secs(5), async {
            while !held.paused.load(Ordering::Acquire) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        // This current-thread test resumes only after pump has reached its
        // credit await, so it observes the allocation's actual lifetime.
        let released = weak.upgrade().is_none();
        drop(credit);
        task.await.unwrap();
        assert!(released, "paused sid retained its replay copy (resume={resume_pending})");
    }
}
