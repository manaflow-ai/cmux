use super::*;
use futures::future::BoxFuture;
use std::sync::mpsc;
use std::time::Duration;

/// A fetch that fails, as every fetch does on a Mac with no route out.
struct Fails;

impl Fetcher for Fails {
    fn fetch<'a>(&'a self, _: Option<&'a str>) -> BoxFuture<'a, Result<FetchOutcome, String>> {
        Box::pin(async { Err("offline".to_owned()) })
    }
}

/// A log writer that blocks until the test lets it go: a daemon's stdout that nobody reads.
#[derive(Clone)]
struct Stuck {
    entered: mpsc::SyncSender<()>,
    release: Arc<Mutex<mpsc::Receiver<()>>>,
}

impl std::io::Write for Stuck {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let _ = self.entered.try_send(());
        let _ = self.release.lock().unwrap_or_else(PoisonError::into_inner).recv();
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// A failed refresh logs its error with the catalog unlocked: a log write that waits (stdout a
/// full pipe) must not stop the requests that read the catalog in use (`current`), each on a
/// tokio worker. aws-m4pro-5, 2026-11-10: a daemon whose log pipe nobody read answered no
/// `acpmux ls` for 2 h 41 min, its request waiting in `current` on this lock.
#[test]
fn a_stuck_log_write_does_not_hold_the_catalog() {
    let service = Arc::new(CatalogService::new());
    service
        .attach(std::env::temp_dir().join("acpmux-catalog-log-lock-none"), Some(Arc::new(Fails)));
    let (entered_tx, entered) = mpsc::sync_channel(1);
    let (release, release_rx) = mpsc::channel::<()>();
    let stuck = Stuck { entered: entered_tx, release: Arc::new(Mutex::new(release_rx)) };
    let refreshing = {
        let service = service.clone();
        std::thread::spawn(move || {
            let logs = tracing_subscriber::fmt().with_writer(move || stuck.clone()).finish();
            tracing::subscriber::with_default(logs, || {
                futures::executor::block_on(service.refresh(true))
            })
        })
    };
    entered.recv_timeout(Duration::from_secs(10)).expect("the refresh logs its failure");
    let (read_tx, read) = mpsc::channel();
    let reader = service.clone();
    std::thread::spawn(move || {
        let _ = read_tx.send(reader.current());
    });
    let answered = read.recv_timeout(Duration::from_secs(5));
    drop(release);
    assert!(answered.is_ok(), "the catalog in use is read while the log write waits");
    let reply = refreshing.join().expect("the refresh ends once the log write does");
    assert_eq!(reply.get("error").and_then(Value::as_str), Some("offline"));
}
