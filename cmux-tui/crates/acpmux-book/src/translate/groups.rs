//! A turn's display groups: how a run of calls and thoughts is split into what the transcript
//! draws (transcript-motion-model.md step 9, "The daemon owns shape"; ledger row d64cc8c88c).
//! Consecutive commands or searches gather under one line ("Ran 3 commands"); an edit run gathers
//! from two calls, or from one whose first call has a diff ("Edited App.tsx +12 -3"); reads never
//! gather, each keeps its row; calls to one MCP tool gather from one call; adjacent sub-session
//! starts gather into one disclosure; two or more sent messages in a row gather into "Sent N
//! messages"; a card keeps its own row. A thought between two commands, reads or searches stays
//! inside their run, in its place; the thoughts that lead into such a run open it; a thought before
//! anything else draws on its own.
//!
//! This is the rule the page's `toolGroups` (webviews conversation/toolGroups.ts) runs today. Both
//! read the shared cases in `fixtures/display-groups-cases.json`, so the page and the daemon cannot
//! drift while the page still groups. What a call *is* ([`Class`]) is given to this module: the
//! classifiers (toolNames.ts `toolKind`, readPath.ts, mcpCalls.ts, acpmuxSends.ts and the card
//! readers) move to Rust next, then the translator writes the groups on rows and the page stops
//! regrouping.

/// The kinds of call that gather with their neighbors (toolGroups.ts `ToolGroupKind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RunKind {
    Commands,
    Reads,
    Edits,
    Searches,
}

/// What one entry of a turn is, for grouping.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Class {
    /// The agent's thinking (consecutive thoughts are one; [`display_groups`] merges them).
    Thought,
    /// A call that gathers with calls of its kind. `diff`: an edit that carries a diff, which
    /// gathers alone.
    Run { kind: RunKind, diff: bool },
    /// A call to an MCP tool, by its key: calls with one key in a row gather.
    Mcp(String),
    /// A sub-session started: adjacent ones gather.
    SubsessionStart,
    /// A call that sent `parts` messages to other agents (a batch is several).
    Sent { parts: u32 },
    /// A coordination card (a dispatch, who-else, a forum post, a subagent call, a sub-session
    /// waited on): its own row.
    Card,
    /// Any other call: its own row.
    Plain,
}

/// One drawn group. Each holds indexes into the entries [`display_groups`] was given.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Group {
    /// A gathered run, with the thoughts inside it in their places.
    Run { kind: RunKind, items: Vec<usize> },
    /// One entry on its own row (a call or a thought).
    Item(usize),
    /// Calls to one MCP tool.
    Mcp(Vec<usize>),
    /// Two or more adjacent sub-session starts.
    SubsessionGroup(Vec<usize>),
    /// A card, or a lone sub-session start.
    Card(usize),
    /// One sent message; a call that sent several is one of these per message.
    Sent(usize),
    /// Two or more sent messages in a row: the calls, each once.
    SentGroup(Vec<usize>),
}

impl Group {
    /// The entries the group holds, in order.
    pub(crate) fn items(&self) -> &[usize] {
        match self {
            Group::Run { items, .. }
            | Group::Mcp(items)
            | Group::SubsessionGroup(items)
            | Group::SentGroup(items) => items,
            Group::Item(at) | Group::Card(at) | Group::Sent(at) => std::slice::from_ref(at),
        }
    }

    /// The entry the group is known by: its first call, since thoughts that led into a run come
    /// before it (toolGroups.ts `groupId`). A group born at its first call keeps that id as it grows.
    pub(crate) fn id(&self, classes: &[Class]) -> usize {
        let items = self.items();
        items.iter().copied().find(|&at| classes[at] != Class::Thought).unwrap_or(items[0])
    }
}

struct Open {
    kind: RunKind,
    items: Vec<usize>,
    /// How many leading thoughts opened it.
    lead: usize,
    /// The first call's `diff`.
    first_diff: bool,
}

#[derive(Default)]
struct Grouper {
    groups: Vec<Group>,
    run: Option<Open>,
    mcp: Option<(String, Vec<usize>)>,
    starts: Vec<usize>,
    /// Thoughts after the open run's latest call: they join it if a call of its kind comes next.
    held: Vec<usize>,
    /// Thoughts no run holds yet: they lead the next run of commands, reads or searches.
    lead: Vec<usize>,
}

impl Grouper {
    fn flush_lead(&mut self) {
        self.groups.extend(self.lead.drain(..).map(Group::Item));
    }

    /// Closes what is open. `keep`: the open run's trailing thoughts wait to lead what comes next.
    fn close(&mut self, keep: bool) {
        match self.starts.len() {
            0 => {}
            1 => self.groups.push(Group::Card(self.starts[0])),
            _ => self.groups.push(Group::SubsessionGroup(std::mem::take(&mut self.starts))),
        }
        self.starts.clear();
        if let Some((_, items)) = self.mcp.take() {
            self.groups.push(Group::Mcp(items));
        }
        if let Some(run) = self.run.take() {
            let calls = run.items.len() - run.lead;
            // Reads never gather under a "Read N files" line (Lucas, 2026-11-14: "we shouldn't
            // nest reading files").
            if run.kind != RunKind::Reads
                && (calls >= 2 || (run.kind == RunKind::Edits && run.first_diff))
            {
                self.groups.push(Group::Run { kind: run.kind, items: run.items });
            } else {
                self.groups.extend(run.items.into_iter().map(Group::Item));
            }
        }
        if keep {
            self.lead.append(&mut self.held);
        } else {
            self.groups.extend(self.held.drain(..).map(Group::Item));
        }
    }
}

/// The groups a turn's entries draw as, in order. Consecutive thoughts count as one: the first
/// stands for them (the page merges their texts, thoughts.ts `mergeThoughts`).
pub(crate) fn display_groups(classes: &[Class]) -> Vec<Group> {
    let mut g = Grouper::default();
    for (at, class) in classes.iter().enumerate() {
        match class {
            Class::Thought => {
                if at > 0 && classes[at - 1] == Class::Thought {
                    continue;
                }
                match &g.run {
                    Some(run) if run.kind != RunKind::Edits => g.held.push(at),
                    _ => {
                        g.close(true);
                        g.lead.push(at);
                    }
                }
            }
            Class::SubsessionStart => {
                if g.starts.is_empty() {
                    g.close(false);
                    g.flush_lead();
                }
                g.starts.push(at);
            }
            Class::Mcp(key) if g.mcp.as_ref().is_some_and(|(open, _)| open == key) => {
                if let Some((_, items)) = &mut g.mcp {
                    items.push(at);
                }
            }
            Class::Run { kind, .. } if g.run.as_ref().is_some_and(|run| run.kind == *kind) => {
                if let Some(run) = &mut g.run {
                    run.items.append(&mut g.held);
                    run.items.push(at);
                }
            }
            _ => {
                g.close(true);
                match class {
                    Class::Run { kind, diff } if *kind != RunKind::Edits => {
                        let lead = std::mem::take(&mut g.lead);
                        let mut items = lead.clone();
                        items.push(at);
                        g.run =
                            Some(Open { kind: *kind, items, lead: lead.len(), first_diff: *diff });
                    }
                    _ => {
                        g.flush_lead();
                        match class {
                            Class::Sent { parts } => {
                                g.groups.extend((0..(*parts).max(1)).map(|_| Group::Sent(at)));
                            }
                            Class::Card => g.groups.push(Group::Card(at)),
                            Class::Mcp(key) => g.mcp = Some((key.clone(), vec![at])),
                            Class::Run { kind, diff } => {
                                g.run = Some(Open {
                                    kind: *kind,
                                    items: vec![at],
                                    lead: 0,
                                    first_diff: *diff,
                                });
                            }
                            _ => g.groups.push(Group::Item(at)),
                        }
                    }
                }
            }
        }
    }
    g.close(false);
    g.flush_lead();
    with_sent_groups(g.groups)
}

/// `groups` with each run of two or more sent messages as one [`Group::SentGroup`].
fn with_sent_groups(groups: Vec<Group>) -> Vec<Group> {
    let mut out = Vec::with_capacity(groups.len());
    let mut sent: Vec<usize> = Vec::new();
    let mut count = 0usize;
    let flush = |out: &mut Vec<Group>, sent: &mut Vec<usize>, count: &mut usize| {
        if *count >= 2 {
            out.push(Group::SentGroup(std::mem::take(sent)));
        } else if let Some(&at) = sent.first() {
            out.push(Group::Sent(at));
        }
        sent.clear();
        *count = 0;
    };
    for group in groups {
        if let Group::Sent(at) = group {
            if sent.last() != Some(&at) {
                sent.push(at);
            }
            count += 1;
            continue;
        }
        flush(&mut out, &mut sent, &mut count);
        out.push(group);
    }
    flush(&mut out, &mut sent, &mut count);
    out
}
