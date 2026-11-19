use super::*;

struct Feed(Vec<u8>);

impl Fetcher for Feed {
    fn fetch<'a>(
        &'a self,
        _: Option<&'a str>,
    ) -> futures::future::BoxFuture<'a, Result<FetchOutcome, String>> {
        Box::pin(async {
            Ok(FetchOutcome::Body { body: self.0.clone(), etag: Some("release-feed".into()) })
        })
    }
}

#[tokio::test]
async fn bundled_only_release_survives_live_refresh_and_stored_reload() {
    let baseline = bundled();
    let mut live = baseline.clone();
    live.generated_at = "2099-01-01T00:00:00.000Z".into();
    live.source = "live".into();
    let harness = live.harnesses.iter_mut().find(|h| h.id == "gemini").unwrap();
    harness.models.retain(|m| m.id != "gemini-4-hydrogen");
    let carbon = harness.models.iter_mut().find(|m| m.id == "gemini-4-carbon").unwrap();
    carbon.name = "Account release name".into();
    carbon.status = Some("deprecated".into());
    let mut future = carbon.clone();
    future.id = "gemini-future".into();
    future.reference = None;
    future.status = None;
    harness.models.insert(0, future);
    harness.default_model = Some("gemini-future".into());
    live.models.remove("google/gemini-4-hydrogen");
    let carbon = live.models.get_mut("google/gemini-4-carbon").unwrap();
    carbon.context_window = Some(123456);
    carbon.cost.as_mut().unwrap().input = Some(42.0);
    let expected_carbon = carbon.clone();
    let dir = tempfile::tempdir().unwrap();
    let service = CatalogService::with_bundled(baseline.clone());
    service.attach(dir.path().to_owned(), Some(Arc::new(Feed(serde_json::to_vec(&live).unwrap()))));
    let reply = service.refresh(true).await;
    assert_eq!(reply["changed"], true);
    let merged = service.current();
    let harness = merged.harnesses.iter().find(|h| h.id == "gemini").unwrap();
    assert_eq!(harness.default_model.as_deref(), Some("gemini-future"));
    let carbon = harness.models.iter().find(|m| m.id == "gemini-4-carbon").unwrap();
    assert_eq!(carbon.name, "Account release name");
    assert_eq!(carbon.status.as_deref(), Some("deprecated"));
    assert_eq!(merged.models["google/gemini-4-carbon"], expected_carbon);
    assert_eq!(
        merged.models["google/gemini-4-hydrogen"],
        baseline.models["google/gemini-4-hydrogen"]
    );
    let ids: Vec<_> = harness.models.iter().map(|m| m.id.as_str()).collect();
    assert_eq!(&ids[..3], &["gemini-future", "gemini-4-carbon", "gemini-4-hydrogen"]);
    assert!(!ids.contains(&"gemini-4-argon"));
    assert_eq!(service.refresh(true).await["changed"], false);
    let reloaded = CatalogService::with_bundled(baseline);
    reloaded.attach(dir.path().to_owned(), None);
    assert_eq!(*reloaded.current(), *merged);
}

#[test]
fn bundled_models_do_not_change_probe_contract_or_reclaim_live_aliases() {
    let baseline = bundled();
    let mut live = baseline.clone();
    let probe = live.harnesses.iter_mut().find(|h| h.id == "gemini").unwrap();
    probe.model_source = "probe".into();
    probe.models.clear();
    probe.default_model = None;
    let claude = live.harnesses.iter_mut().find(|h| h.id == "claude").unwrap();
    claude.models.clear();
    let mut future =
        baseline.harnesses.iter().find(|h| h.id == "claude").unwrap().models[0].clone();
    future.id = "future-opus".into();
    future.aliases = Some(vec!["opus".into()]);
    claude.models.push(future);
    claude.default_model = Some("future-opus".into());
    let merged = merge::with_bundled(live, &baseline);
    assert!(merged.harnesses.iter().find(|h| h.id == "gemini").unwrap().models.is_empty());
    let claude = merged.harnesses.iter().find(|h| h.id == "claude").unwrap();
    let aliases: Vec<_> = claude
        .models
        .iter()
        .filter(|m| m.aliases.as_ref().is_some_and(|a| a.iter().any(|a| a == "opus")))
        .collect();
    assert_eq!(aliases.len(), 1);
    assert_eq!(aliases[0].id, "future-opus");
    assert_eq!(merge::with_bundled(merged.clone(), &baseline), merged);
}
