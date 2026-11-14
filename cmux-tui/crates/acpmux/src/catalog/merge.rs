use std::collections::{HashMap, HashSet};

use super::{Catalog, CatalogHarness};

/// A feed may lag a release already shipped with NEXT. Keep its complete entries
/// (including prices, defaults and deprecations), filling only missing identities.
pub(super) fn with_bundled(mut live: Catalog, bundled: &Catalog) -> Catalog {
    for baseline in &bundled.harnesses {
        if let Some(harness) = live.harnesses.iter_mut().find(|h| h.id == baseline.id) {
            if harness.model_source == "catalog" && baseline.model_source == "catalog" {
                merge_models(harness, baseline);
            }
        } else {
            live.harnesses.push(baseline.clone());
        }
    }
    for (id, model) in &bundled.models {
        live.models.entry(id.clone()).or_insert_with(|| model.clone());
    }
    for (id, provider) in &bundled.providers {
        live.providers.entry(id.clone()).or_insert_with(|| provider.clone());
    }
    live
}

fn merge_models(live: &mut CatalogHarness, bundled: &CatalogHarness) {
    let ids: HashSet<_> = live.models.iter().map(|m| m.id.clone()).collect();
    let claimed: HashSet<_> = live
        .models
        .iter()
        .flat_map(|m| std::iter::once(m.id.clone()).chain(m.aliases.iter().flatten().cloned()))
        .collect();
    for model in &bundled.models {
        if !ids.contains(&model.id) && !claimed.contains(&model.id) {
            let mut model = model.clone();
            if let Some(aliases) = &mut model.aliases {
                aliases.retain(|alias| !claimed.contains(alias));
            }
            live.models.push(model);
        }
    }
    let mut ranks = HashMap::new();
    let mut model_ranks = HashMap::new();
    for model in &bundled.models {
        if let Some(family) = &model.family {
            let next = ranks.len();
            let rank = *ranks.entry(family.as_str()).or_insert(next);
            model_ranks.insert(model.id.as_str(), rank);
        }
    }
    // Stable sort: live ordering within a family survives (including newer releases),
    // while bundled-only families occupy their published place in the picker.
    live.models.sort_by_key(|model| {
        model_ranks
            .get(model.id.as_str())
            .copied()
            .or_else(|| model.family.as_deref().and_then(|family| ranks.get(family)).copied())
            .unwrap_or(ranks.len())
    });
}
