//! What a new-chat composer holds before its chat exists: the harness, account, model, effort
//! and permission mode, as one state machine (Leo 2026-11-22: "all the ... initial state and all
//! the state transitions across permissions, models, harnesses, accounts ... design out the bad
//! states. fundamentally.").
//!
//! One value, [`Selection`], is both what the composer shows and what the start sends, so the two
//! cannot differ. Its first value comes from the harness's [`Offer`], which the daemon fills from
//! the functions `session/new` itself starts a chat with (`hub/composer_view.rs`). Every change
//! goes through [`World::apply`] or [`World::settle`], which are total: whatever is picked, and
//! whatever the selection came from (another harness, another machine, a forked or resumed
//! chat), the result names only what the harness offers and leaves nothing it runs unnamed
//! ([`World::holds`]). The clients draw the selection; none of them decides one.
//!
//! Pure: no IO, no clock, no daemon state.

use std::collections::BTreeMap;

/// One model a harness offers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModelOffer {
    pub id: String,
    /// The effort levels it takes; empty for a model with no effort.
    pub efforts: Vec<String>,
    /// The level it runs at when none is picked. A model with efforts names one ([`World::flaw`]).
    pub default_effort: Option<String>,
}

/// What one harness offers a new chat on one machine, and what such a chat starts on.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Offer {
    /// Its models; empty when it reports none (it then runs its own, which nothing names).
    pub models: Vec<ModelOffer>,
    /// The model a new chat starts on.
    pub start_model: Option<String>,
    /// The effort a new chat on `start_model` is set to (a saved pick, else the model's default).
    pub start_effort: Option<String>,
    /// Its permission modes; empty for a harness with none.
    pub modes: Vec<String>,
    /// The mode a new chat runs in.
    pub start_mode: Option<String>,
    /// The accounts it can run under; empty when it has one login nothing names.
    pub accounts: Vec<String>,
    /// The account a new chat runs under.
    pub start_account: Option<String>,
}

/// The harnesses one machine offers one kind of caller. Another machine, and a remote device on
/// the same machine, is another world: the selection moves between them with [`World::settle`].
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct World {
    pub harnesses: BTreeMap<String, Offer>,
    /// The harness a new chat uses when none is named.
    pub default_harness: Option<String>,
}

/// What the composer shows, and what the chat starts with. A field is `None` only when the
/// harness has nothing of that kind (no models listed, a model with no effort, no modes, no
/// accounts): never for a value the chat would run and the composer would not name.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Selection {
    pub harness: String,
    pub account: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub mode: Option<String>,
}

/// One thing the person picks in the composer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Pick {
    Harness(String),
    Account(String),
    Model(String),
    Effort(String),
    Mode(String),
}

impl Offer {
    fn model(&self, id: &str) -> Option<&ModelOffer> {
        self.models.iter().find(|m| m.id == id)
    }

    /// The model a selection holds when it names none this harness offers: the start model, else
    /// the first listed.
    fn model_or_start(&self, wanted: Option<&str>) -> Option<&ModelOffer> {
        wanted
            .and_then(|id| self.model(id))
            .or_else(|| self.start_model.as_deref().and_then(|id| self.model(id)))
            .or_else(|| self.models.first())
    }

    /// The effort a chat on `model` runs at: `wanted` when the model takes it, else the start
    /// effort when this is the start model and it takes that, else the model's default, else its
    /// first level. None only for a model with no effort.
    fn effort_for(&self, model: &ModelOffer, wanted: Option<&str>) -> Option<String> {
        let takes = |level: &str| model.efforts.iter().any(|e| e == level);
        let start = (self.start_model.as_deref() == Some(model.id.as_str()))
            .then_some(self.start_effort.as_deref())
            .flatten();
        wanted
            .filter(|level| takes(level))
            .or(start.filter(|level| takes(level)))
            .or(model.default_effort.as_deref().filter(|level| takes(level)))
            .or(model.efforts.first().map(String::as_str))
            .map(str::to_owned)
    }

    /// `wanted` when offered, else the start value when offered, else the first offered.
    fn one_of(list: &[String], wanted: Option<&str>, start: Option<&str>) -> Option<String> {
        let offered = |value: &str| list.iter().any(|x| x == value);
        wanted
            .filter(|value| offered(value))
            .or(start.filter(|value| offered(value)))
            .or(list.first().map(String::as_str))
            .map(str::to_owned)
    }

    /// The selection on this harness nearest to the wanted values: each kept when the harness
    /// offers it, else its start value.
    fn select(
        &self,
        harness: &str,
        account: Option<&str>,
        model: Option<&str>,
        effort: Option<&str>,
        mode: Option<&str>,
    ) -> Selection {
        let chosen = self.model_or_start(model);
        Selection {
            harness: harness.to_owned(),
            account: Self::one_of(&self.accounts, account, self.start_account.as_deref()),
            model: chosen.map(|m| m.id.clone()),
            effort: chosen.and_then(|m| self.effort_for(m, effort)),
            mode: Self::one_of(&self.modes, mode, self.start_mode.as_deref()),
        }
    }
}

impl World {
    /// The harness a selection lands on when it names none this world offers: the default, else
    /// the first. None for a world with no harness.
    fn harness_or_default<'a>(&'a self, wanted: Option<&str>) -> Option<(&'a str, &'a Offer)> {
        let named = |id: &str| self.harnesses.get_key_value(id);
        wanted
            .and_then(named)
            .or_else(|| self.default_harness.as_deref().and_then(named))
            .or_else(|| self.harnesses.iter().next())
            .map(|(id, offer)| (id.as_str(), offer))
    }

    /// The composer's first selection: `harness` (the default harness when none, or when this
    /// world does not offer it) with everything it starts a new chat on. None for a world with no
    /// harness.
    pub fn initial(&self, harness: Option<&str>) -> Option<Selection> {
        let (id, offer) = self.harness_or_default(harness)?;
        Some(offer.select(id, None, None, None, None))
    }

    /// `selection` as this world can run it: itself when it holds here, else the nearest one
    /// that does. It is how a selection made elsewhere enters a composer: one made before the
    /// harnesses changed, on another machine, or read from the chat a fork or a resume continues.
    /// None for a world with no harness.
    pub fn settle(&self, selection: &Selection) -> Option<Selection> {
        let (id, offer) = self.harness_or_default(Some(&selection.harness))?;
        if id != selection.harness {
            // Another harness's model, effort, mode and account name nothing here.
            return Some(offer.select(id, None, None, None, None));
        }
        Some(offer.select(
            id,
            selection.account.as_deref(),
            selection.model.as_deref(),
            selection.effort.as_deref(),
            selection.mode.as_deref(),
        ))
    }

    /// The selection after one pick. A pick this world does not offer (a mode the harness lacks,
    /// an effort the model does not take, a harness that is gone) changes nothing. A new harness
    /// starts on its own start values; a new model keeps the effort when it takes it and takes
    /// its own otherwise; a model with no effort holds none. None for a world with no harness.
    pub fn apply(&self, selection: &Selection, pick: &Pick) -> Option<Selection> {
        let now = self.settle(selection)?;
        let offer = self.harnesses.get(&now.harness)?;
        let offered = |list: &[String], value: &str| list.iter().any(|x| x == value);
        Some(match pick {
            Pick::Harness(id) if *id != now.harness => match self.harnesses.get_key_value(id) {
                Some((id, other)) => other.select(id, None, None, None, None),
                None => now,
            },
            Pick::Harness(_) => now,
            Pick::Account(id) if offered(&offer.accounts, id) => {
                Selection { account: Some(id.clone()), ..now }
            }
            Pick::Model(id) => match offer.model(id) {
                Some(model) => Selection {
                    model: Some(model.id.clone()),
                    effort: offer.effort_for(model, now.effort.as_deref()),
                    ..now
                },
                None => now,
            },
            Pick::Effort(level) => {
                let takes = now
                    .model
                    .as_deref()
                    .and_then(|id| offer.model(id))
                    .is_some_and(|model| offered(&model.efforts, level));
                if takes { Selection { effort: Some(level.clone()), ..now } } else { now }
            }
            Pick::Mode(id) if offered(&offer.modes, id) => {
                Selection { mode: Some(id.clone()), ..now }
            }
            Pick::Account(_) | Pick::Mode(_) => now,
        })
    }

    /// Why `selection` is not one this world can run as shown, or None when it is: its harness
    /// exists, each field names something the harness offers, and no field is empty while the
    /// harness has something of that kind.
    pub fn broken(&self, selection: &Selection) -> Option<String> {
        let Some(offer) = self.harnesses.get(&selection.harness) else {
            return Some(format!("no harness {}", selection.harness));
        };
        let one = |what: &str, list: &[String], value: &Option<String>| match value {
            Some(v) if !list.iter().any(|x| x == v) => Some(format!("{what} {v} is not offered")),
            None if !list.is_empty() => Some(format!("no {what} is named, and one runs")),
            _ => None,
        };
        let model = match &selection.model {
            Some(id) => match offer.model(id) {
                Some(model) => Some(model),
                None => return Some(format!("model {id} is not offered")),
            },
            None if !offer.models.is_empty() => {
                return Some("no model is named, and one runs".to_owned());
            }
            None => None,
        };
        let efforts = model.map(|m| m.efforts.as_slice()).unwrap_or_default();
        one("account", &offer.accounts, &selection.account)
            .or_else(|| one("effort", efforts, &selection.effort))
            .or_else(|| one("mode", &offer.modes, &selection.mode))
    }

    /// Whether `selection` is one this world can run as shown ([`World::broken`]).
    pub fn holds(&self, selection: &Selection) -> bool {
        self.broken(selection).is_none()
    }

    /// Why this world's own start values would not be shown as they run, or None: the default
    /// harness exists, and every start value names something its harness offers. A model with
    /// efforts names its default. The daemon's own worlds are checked against it in tests, so a
    /// catalog or a start rule that hides a value fails there.
    pub fn flaw(&self) -> Option<String> {
        if let Some(id) = &self.default_harness
            && !self.harnesses.contains_key(id)
        {
            return Some(format!("the default harness {id} is not offered"));
        }
        for (id, offer) in &self.harnesses {
            let named = |what: &str, list: &[String], value: &Option<String>| match value {
                Some(v) if !list.iter().any(|x| x == v) => {
                    Some(format!("{id}: start {what} {v} is not offered"))
                }
                None if !list.is_empty() => Some(format!("{id}: no start {what}")),
                _ => None,
            };
            let models: Vec<String> = offer.models.iter().map(|m| m.id.clone()).collect();
            let start = offer.start_model.as_deref().and_then(|m| offer.model(m));
            let efforts = start.map(|m| m.efforts.as_slice()).unwrap_or_default();
            let flaw = named("model", &models, &offer.start_model)
                .or_else(|| named("effort", efforts, &offer.start_effort))
                .or_else(|| named("mode", &offer.modes, &offer.start_mode))
                .or_else(|| named("account", &offer.accounts, &offer.start_account))
                .or_else(|| {
                    offer.models.iter().find_map(|m| {
                        named(&format!("default effort of {}", m.id), &m.efforts, &m.default_effort)
                    })
                });
            if flaw.is_some() {
                return flaw;
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| (*s).to_owned()).collect()
    }

    fn model(id: &str, efforts: &[&str], default_effort: Option<&str>) -> ModelOffer {
        ModelOffer {
            id: id.to_owned(),
            efforts: strings(efforts),
            default_effort: default_effort.map(str::to_owned),
        }
    }

    /// Every shape one harness can take: its models (none, one with no effort, one with efforts,
    /// a mix where the two take different levels), its modes (none, one, three) and its accounts
    /// (none, two), each with every start value it could have.
    fn offers() -> Vec<Offer> {
        let model_sets: Vec<Vec<ModelOffer>> = vec![
            vec![],
            vec![model("plain", &[], None)],
            vec![model("thinker", &["low", "medium", "high"], Some("medium"))],
            vec![
                model("thinker", &["low", "medium", "high"], Some("medium")),
                model("plain", &[], None),
                model("deep", &["high", "xhigh"], Some("high")),
            ],
        ];
        let mode_sets = [strings(&[]), strings(&["ask"]), strings(&["ask", "auto", "full"])];
        let account_sets = [strings(&[]), strings(&["work", "home"])];
        let mut all = Vec::new();
        for models in &model_sets {
            // Each start model, and for each its start effort: every level it takes.
            let starts: Vec<Option<&ModelOffer>> =
                if models.is_empty() { vec![None] } else { models.iter().map(Some).collect() };
            for start in starts {
                let efforts: Vec<Option<String>> = match start {
                    Some(m) if !m.efforts.is_empty() => {
                        m.efforts.iter().cloned().map(Some).collect()
                    }
                    _ => vec![None],
                };
                for start_effort in efforts {
                    for modes in &mode_sets {
                        let start_modes: Vec<Option<String>> = if modes.is_empty() {
                            vec![None]
                        } else {
                            modes.iter().cloned().map(Some).collect()
                        };
                        for start_mode in start_modes {
                            for accounts in &account_sets {
                                all.push(Offer {
                                    models: models.clone(),
                                    start_model: start.map(|m| m.id.clone()),
                                    start_effort: start_effort.clone(),
                                    modes: modes.clone(),
                                    start_mode: start_mode.clone(),
                                    accounts: accounts.clone(),
                                    start_account: accounts.last().cloned(),
                                });
                            }
                        }
                    }
                }
            }
        }
        all
    }

    /// Every pick a composer could send in a world of these offers, the ones no harness offers
    /// included (`ghost`, and each harness's values sent to the other).
    fn picks() -> Vec<Pick> {
        let mut all = Vec::new();
        for id in ["a", "b", "ghost"] {
            all.push(Pick::Harness(id.to_owned()));
        }
        for id in ["work", "home", "ghost"] {
            all.push(Pick::Account(id.to_owned()));
        }
        for id in ["plain", "thinker", "deep", "ghost"] {
            all.push(Pick::Model(id.to_owned()));
        }
        for id in ["low", "medium", "high", "xhigh", "ghost"] {
            all.push(Pick::Effort(id.to_owned()));
        }
        for id in ["ask", "auto", "full", "ghost"] {
            all.push(Pick::Mode(id.to_owned()));
        }
        all
    }

    fn world(a: &Offer, b: &Offer) -> World {
        World {
            harnesses: BTreeMap::from([("a".to_owned(), a.clone()), ("b".to_owned(), b.clone())]),
            default_harness: Some("a".to_owned()),
        }
    }

    /// The field a pick names, when the selection took it.
    fn took(selection: &Selection, pick: &Pick) -> bool {
        match pick {
            Pick::Harness(id) => selection.harness == *id,
            Pick::Account(id) => selection.account.as_ref() == Some(id),
            Pick::Model(id) => selection.model.as_ref() == Some(id),
            Pick::Effort(id) => selection.effort.as_ref() == Some(id),
            Pick::Mode(id) => selection.mode.as_ref() == Some(id),
        }
    }

    /// Whether `world` offers `pick` to a composer holding `selection`.
    fn offered(world: &World, selection: &Selection, pick: &Pick) -> bool {
        let offer = &world.harnesses[&selection.harness];
        let has = |list: &[String], id: &String| list.contains(id);
        match pick {
            Pick::Harness(id) => world.harnesses.contains_key(id),
            Pick::Account(id) => has(&offer.accounts, id),
            Pick::Model(id) => offer.model(id).is_some(),
            Pick::Effort(id) => selection
                .model
                .as_deref()
                .and_then(|m| offer.model(m))
                .is_some_and(|m| has(&m.efforts, id)),
            Pick::Mode(id) => has(&offer.modes, id),
        }
    }

    #[test]
    fn every_generated_world_is_sound() {
        let offers = offers();
        assert!(offers.len() > 100, "the product is the point: {}", offers.len());
        for offer in &offers {
            assert_eq!(world(offer, offer).flaw(), None, "{offer:?}");
        }
    }

    /// The whole product: every pair of harness shapes, every first harness, every pick, then
    /// every second pick. After each step the selection is one the world runs as shown; a pick
    /// the world offers is taken exactly; one it does not offer changes nothing; and the first
    /// selection is the harness's own start values.
    #[test]
    fn every_pick_from_every_start_leaves_a_selection_that_runs_as_shown() {
        let offers = offers();
        let picks = picks();
        // Every shape against a fixed set of second harnesses that differ in every axis.
        let others: Vec<&Offer> = [0, offers.len() / 3, offers.len() / 2, offers.len() - 1]
            .iter()
            .map(|i| &offers[*i])
            .collect();
        let mut steps = 0_u64;
        for a in &offers {
            for b in &others {
                let world = world(a, b);
                for first in ["a", "b"] {
                    let start = world.initial(Some(first)).unwrap();
                    assert_eq!(world.broken(&start), None, "{start:?} in {world:?}");
                    let offer = &world.harnesses[first];
                    assert_eq!(start.harness, first);
                    assert_eq!(start.model, offer.start_model, "starts on the start model");
                    assert_eq!(start.effort, offer.start_effort, "and its start effort");
                    assert_eq!(start.mode, offer.start_mode, "in the start mode");
                    assert_eq!(start.account, offer.start_account, "under the start account");
                    for one in &picks {
                        let after = world.apply(&start, one).unwrap();
                        check(&world, &start, one, &after);
                        for two in &picks {
                            let last = world.apply(&after, two).unwrap();
                            check(&world, &after, two, &last);
                            steps += 1;
                        }
                    }
                }
            }
        }
        assert!(steps > 100_000, "the product ran: {steps}");
    }

    fn check(world: &World, before: &Selection, pick: &Pick, after: &Selection) {
        assert_eq!(world.broken(after), None, "{before:?} + {pick:?} = {after:?} in {world:?}");
        if offered(world, before, pick) {
            assert!(
                took(after, pick),
                "{before:?} + {pick:?} = {after:?}: an offered pick is taken"
            );
        } else {
            assert_eq!(after, before, "{pick:?} is not offered: nothing changes");
        }
        // A pick changes only what it names, and what cannot stay: a model pick may move the
        // effort, a harness pick moves everything.
        match pick {
            Pick::Harness(_) => {}
            Pick::Model(_) => {
                assert_eq!(
                    (&after.harness, &after.account, &after.mode),
                    (&before.harness, &before.account, &before.mode)
                );
                let kept = world.harnesses[&after.harness]
                    .model(after.model.as_deref().unwrap_or_default())
                    .is_some_and(|m| before.effort.as_ref().is_some_and(|e| m.efforts.contains(e)));
                if kept {
                    assert_eq!(after.effort, before.effort, "an effort the new model takes stays");
                }
            }
            Pick::Account(_) => assert_eq!(
                (&after.harness, &after.model, &after.effort, &after.mode),
                (&before.harness, &before.model, &before.effort, &before.mode)
            ),
            Pick::Effort(_) => assert_eq!(
                (&after.harness, &after.account, &after.model, &after.mode),
                (&before.harness, &before.account, &before.model, &before.mode)
            ),
            Pick::Mode(_) => assert_eq!(
                (&after.harness, &after.account, &after.model, &after.effort),
                (&before.harness, &before.account, &before.model, &before.effort)
            ),
        }
        // Settling a selection that already holds changes nothing.
        assert_eq!(world.settle(after).as_ref(), Some(after));
    }

    /// A selection made in one world (another machine, a remote device's view of this one, the
    /// chat a fork or a resume continues) settles into any other: it holds there, keeps every
    /// value the new world offers, and a world it already held in leaves it alone.
    #[test]
    fn a_selection_from_any_world_settles_into_any_other() {
        let offers = offers();
        let step = (offers.len() / 40).max(1);
        let sample: Vec<&Offer> = offers.iter().step_by(step).collect();
        for from in &sample {
            let there = world(from, from);
            for first in [Pick::Mode("full".to_owned()), Pick::Model("deep".to_owned())] {
                let start = there.initial(None).unwrap();
                let made = there.apply(&start, &first).unwrap();
                for to in &offers {
                    let here = world(to, to);
                    let settled = here.settle(&made).unwrap();
                    assert_eq!(here.broken(&settled), None, "{made:?} into {here:?}");
                    let offer = &here.harnesses["a"];
                    if made.mode.as_ref().is_some_and(|m| offer.modes.contains(m)) {
                        assert_eq!(settled.mode, made.mode, "an offered mode is kept");
                    }
                    if made.model.as_deref().is_some_and(|m| offer.model(m).is_some()) {
                        assert_eq!(settled.model, made.model, "an offered model is kept");
                    }
                    if here.holds(&made) {
                        assert_eq!(settled, made);
                    }
                }
            }
        }
    }

    /// The cases the brief names, one by one.
    #[test]
    fn the_named_transitions() {
        let claude = Offer {
            models: vec![
                model("opus", &["low", "medium", "high"], Some("medium")),
                model("haiku", &[], None),
                model("fable", &["high", "xhigh"], Some("high")),
            ],
            start_model: Some("opus".to_owned()),
            start_effort: Some("medium".to_owned()),
            modes: strings(&["default", "auto", "bypassPermissions"]),
            start_mode: Some("auto".to_owned()),
            accounts: strings(&["work", "home"]),
            start_account: Some("work".to_owned()),
        };
        let codex = Offer {
            models: vec![model("sol", &["medium", "high"], Some("high"))],
            start_model: Some("sol".to_owned()),
            start_effort: Some("high".to_owned()),
            modes: strings(&["agent", "agent-full-access"]),
            start_mode: Some("agent-full-access".to_owned()),
            ..Offer::default()
        };
        let pi = Offer::default();
        let world = World {
            harnesses: BTreeMap::from([
                ("claude".to_owned(), claude),
                ("codex".to_owned(), codex),
                ("pi".to_owned(), pi),
            ]),
            default_harness: Some("claude".to_owned()),
        };
        assert_eq!(world.flaw(), None);
        // The first frame: Opus at Medium in Auto, named, never a bare model or "Mode".
        let start = world.initial(None).unwrap();
        assert_eq!(
            (start.model.as_deref(), start.effort.as_deref(), start.mode.as_deref()),
            (Some("opus"), Some("medium"), Some("auto"))
        );
        let pick = |s: &Selection, p: Pick| world.apply(s, &p).unwrap();
        // A model with no effort holds none; back on a model with effort, its own default.
        let haiku = pick(&start, Pick::Model("haiku".to_owned()));
        assert_eq!((haiku.effort.as_deref(), haiku.mode.as_deref()), (None, Some("auto")));
        let back = pick(&haiku, Pick::Model("opus".to_owned()));
        assert_eq!(back.effort.as_deref(), Some("medium"));
        // An effort the next model takes stays; one it does not gives way to that model's own.
        let high = pick(&start, Pick::Effort("high".to_owned()));
        assert_eq!(pick(&high, Pick::Model("fable".to_owned())).effort.as_deref(), Some("high"));
        let low = pick(&start, Pick::Effort("low".to_owned()));
        assert_eq!(pick(&low, Pick::Model("fable".to_owned())).effort.as_deref(), Some("high"));
        // Another harness starts on its own values: Claude's mode and account name nothing there.
        let codex = pick(&high, Pick::Harness("codex".to_owned()));
        assert_eq!(
            (
                codex.model.as_deref(),
                codex.effort.as_deref(),
                codex.mode.as_deref(),
                codex.account.as_deref()
            ),
            (Some("sol"), Some("high"), Some("agent-full-access"), None)
        );
        // A mode the harness lacks is not taken.
        assert_eq!(pick(&codex, Pick::Mode("auto".to_owned())), codex);
        // A harness with no models and no modes shows neither, and holds.
        let pi = pick(&codex, Pick::Harness("pi".to_owned()));
        assert_eq!((&pi.model, &pi.effort, &pi.mode, &pi.account), (&None, &None, &None, &None));
        assert!(world.holds(&pi));
        // An account pick moves nothing else.
        let home = pick(&high, Pick::Account("home".to_owned()));
        assert_eq!(
            (home.model, home.effort, home.mode),
            (high.model.clone(), high.effort.clone(), high.mode.clone())
        );
        // A remote host is another world: full access is not offered there, so a selection that
        // held it settles on that world's start mode, and keeps its model and effort.
        let mut remote = world.clone();
        let there = remote.harnesses.get_mut("claude").unwrap();
        there.modes = strings(&["default"]);
        there.start_mode = Some("default".to_owned());
        let full = pick(&high, Pick::Mode("bypassPermissions".to_owned()));
        let settled = remote.settle(&full).unwrap();
        assert_eq!(
            (settled.model.as_deref(), settled.effort.as_deref(), settled.mode.as_deref()),
            (Some("opus"), Some("high"), Some("default"))
        );
        // A fork or a resumed chat seeds the composer with the chat's own values, settled: a
        // retired model gives way to the start model, the rest stays.
        let old = Selection {
            model: Some("retired".to_owned()),
            effort: Some("max".to_owned()),
            ..full.clone()
        };
        let seeded = world.settle(&old).unwrap();
        assert_eq!(
            (seeded.model.as_deref(), seeded.effort.as_deref(), seeded.mode.as_deref()),
            (Some("opus"), Some("medium"), Some("bypassPermissions"))
        );
        // A harness that is gone lands on the default harness's start.
        let gone = Selection { harness: "gone".to_owned(), ..full };
        assert_eq!(world.settle(&gone), world.initial(None));
    }

    /// What `flaw` refuses: the worlds whose start would hide a value.
    #[test]
    fn a_world_that_would_hide_a_start_value_is_flawed() {
        let sound = Offer {
            models: vec![model("opus", &["medium", "high"], Some("medium"))],
            start_model: Some("opus".to_owned()),
            start_effort: Some("medium".to_owned()),
            modes: strings(&["ask", "auto"]),
            start_mode: Some("auto".to_owned()),
            ..Offer::default()
        };
        let flaw = |offer: Offer| world(&offer, &offer).flaw();
        assert_eq!(flaw(sound.clone()), None);
        // The two Leo named: modes with no start mode ("Mode"), a model with no effort named.
        assert!(flaw(Offer { start_mode: None, ..sound.clone() }).is_some());
        assert!(flaw(Offer { start_effort: None, ..sound.clone() }).is_some());
        assert!(flaw(Offer { start_model: None, ..sound.clone() }).is_some());
        assert!(flaw(Offer { start_mode: Some("gone".to_owned()), ..sound.clone() }).is_some());
        assert!(
            flaw(Offer { models: vec![model("opus", &["medium"], None)], ..sound.clone() })
                .is_some()
        );
        let lost = World { default_harness: Some("gone".to_owned()), ..world(&sound, &sound) };
        assert!(lost.flaw().is_some());
    }
}
