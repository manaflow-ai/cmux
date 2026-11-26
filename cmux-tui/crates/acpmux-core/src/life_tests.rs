use super::*;
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

#[tokio::test(start_paused = true)]
async fn a_panic_restarts_through_the_factory_after_a_wait() {
    let scope = Scope::new("supervision-test");
    let starts = Arc::new(AtomicUsize::new(0));
    let (health, _) = watch::channel(Health::Starting);
    let policy = Policy { first_wait: Duration::from_millis(10), ..Policy::default() };
    let before = Instant::now();
    let result = supervise(
        &scope,
        || {
            let starts = Arc::clone(&starts);
            async move {
                if starts.fetch_add(1, Ordering::SeqCst) == 0 {
                    panic!("injected actor panic");
                }
                Ok::<_, ()>(42)
            }
        },
        policy,
        health,
    )
    .await;
    assert!(matches!(result, Ok(42)));
    assert_eq!(starts.load(Ordering::SeqCst), 2);
    assert!(before.elapsed() >= policy.first_wait);
    assert!(scope.close(Duration::from_secs(1)).await.joined());
}

#[tokio::test(start_paused = true)]
async fn an_actor_error_uses_the_same_restart_wait_as_a_panic() {
    let scope = Scope::new("supervision-test");
    let starts = Arc::new(AtomicUsize::new(0));
    let (health, _) = watch::channel(Health::Starting);
    let policy = Policy { first_wait: Duration::from_millis(10), ..Policy::default() };
    let result = supervise(
        &scope,
        || {
            let starts = Arc::clone(&starts);
            async move {
                if starts.fetch_add(1, Ordering::SeqCst) < 2 {
                    Err::<u32, _>(())
                } else {
                    Ok::<u32, _>(42)
                }
            }
        },
        policy,
        health,
    )
    .await;
    assert!(matches!(result, Ok(42)));
    assert_eq!(starts.load(Ordering::SeqCst), 3);
    assert!(scope.close(Duration::from_secs(1)).await.joined());
}

#[tokio::test(start_paused = true)]
async fn five_panics_fail_the_chat_without_a_sixth_immediate_start() {
    let scope = Arc::new(Scope::new("supervision-test"));
    let owned_scope = Arc::clone(&scope);
    let starts = Arc::new(AtomicUsize::new(0));
    let owned = Arc::clone(&starts);
    let (health, mut receiver) = watch::channel(Health::Starting);
    let policy = Policy { first_wait: Duration::from_millis(1), ..Policy::default() };
    let supervisor = tokio::spawn(async move {
        supervise(
            &owned_scope,
            move || {
                let starts = Arc::clone(&owned);
                async move {
                    starts.fetch_add(1, Ordering::SeqCst);
                    panic!("injected actor panic");
                    #[allow(unreachable_code)]
                    Ok::<(), ()>(())
                }
            },
            policy,
            health,
        )
        .await
    });
    let observed = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if *receiver.borrow_and_update() == Health::Failed {
                break;
            }
            if receiver.changed().await.is_err() {
                break;
            }
        }
    })
    .await;
    assert!(observed.is_ok());
    assert_eq!(*receiver.borrow(), Health::Failed);
    assert_eq!(starts.load(Ordering::SeqCst), 5);
    supervisor.abort();
    assert!(supervisor.await.is_err());
    assert!(scope.close(Duration::from_secs(1)).await.joined());
}

#[tokio::test(start_paused = true)]
async fn cancelling_the_supervisor_also_cancels_its_writer() {
    struct Writer(watch::Sender<bool>);
    impl Drop for Writer {
        fn drop(&mut self) {
            self.0.send_replace(true);
        }
    }
    let scope = Arc::new(Scope::new("supervision-test"));
    let owned_scope = Arc::clone(&scope);
    let (closed, mut receiver) = watch::channel(false);
    let (started, mut ready) = watch::channel(false);
    let (health, _) = watch::channel(Health::Starting);
    let supervisor = tokio::spawn(async move {
        supervise(
            &owned_scope,
            move || {
                let writer = Writer(closed.clone());
                let started = started.clone();
                async move {
                    let _writer = writer;
                    started.send_replace(true);
                    std::future::pending::<Result<(), ()>>().await
                }
            },
            Policy::default(),
            health,
        )
        .await
    });
    assert!(ready.changed().await.is_ok());
    supervisor.abort();
    assert!(supervisor.await.is_err());
    assert!(receiver.changed().await.is_ok());
    assert!(*receiver.borrow());
    assert!(scope.close(Duration::from_secs(1)).await.joined());
}
