//! [`Machine`]'s step: Swift `LinkMachine.handle` and its helpers, arm for arm.

use std::time::Duration;

use super::{Effect, Event, Generation, Machine, Phase, Refusal, SILENT_RETRIES, Target, VideoMedia};
use crate::dial::TransportKind;

impl Machine {
    /// The step in place. Every refusal is decided before anything is written.
    pub(super) fn apply(&mut self, event: &Event) -> Result<Vec<Effect>, Refusal> {
        if self.phase == Phase::SignedOut {
            // Terminal: a target change is recorded, never dialed.
            return match event {
                Event::Target(next) => {
                    self.target = next.clone();
                    Ok(Vec::new())
                }
                Event::Transport(_)
                | Event::RelayOnly(_)
                | Event::BlockUdp(_)
                | Event::DialSucceeded { .. }
                | Event::DialFailed { .. }
                | Event::LinkUpdated { .. }
                | Event::MediaUpdated { .. }
                | Event::LinkDropped { .. }
                | Event::RetryDue { .. }
                | Event::Foreground
                | Event::Open
                | Event::Background
                | Event::Resume
                | Event::ProbeFailed { .. }
                | Event::MacSignaled
                | Event::NetworkChanged
                | Event::SignedOut { .. }
                | Event::StandbyAlive { .. }
                | Event::StandbyLost { .. } => Err(Refusal::SignedOut),
            };
        }
        match event {
            Event::SignedOut { generation } => {
                self.current(*generation)?;
                Ok(self.reset(Phase::SignedOut))
            }
            Event::Background => {
                self.is_backgrounded = true;
                Ok(Vec::new())
            }
            Event::Resume => {
                if !self.is_backgrounded {
                    return self.apply(&Event::Foreground);
                }
                self.is_backgrounded = false;
                if self.phase.is_active() {
                    return Ok(self.dial(1, true));
                }
                Ok(self.apply(&Event::Foreground).unwrap_or_default())
            }
            Event::Target(next) => Ok(self.retarget(next.as_ref())),
            Event::Transport(next) => {
                if *next == self.transport {
                    return Err(Refusal::Unchanged);
                }
                self.transport = *next;
                Ok(self.redial_if_online(true))
            }
            Event::RelayOnly(next) => {
                if *next == self.relay_only {
                    return Err(Refusal::Unchanged);
                }
                self.relay_only = *next;
                Ok(self.redial_if_online(true))
            }
            Event::BlockUdp(next) => {
                if *next == self.block_udp {
                    return Err(Refusal::Unchanged);
                }
                self.block_udp = *next;
                // WebRTC ignores it: no redial (the next WireGuard dial uses it).
                Ok(self.redial_if_online(self.transport == TransportKind::WireGuard))
            }
            Event::DialSucceeded { generation, path } => {
                self.current(*generation)?;
                if !matches!(self.phase, Phase::Connecting { .. }) {
                    return Err(Refusal::NotConnecting);
                }
                self.phase = Phase::Connected { transport: self.transport, path: *path, rtt_millis: None };
                // The new link is up: the old one beside it has nothing left to do.
                Ok(self.drop_standby())
            }
            Event::StandbyAlive { generation, path, rtt_millis } => {
                self.current_standby(*generation)?;
                self.standby = None;
                match self.phase {
                    Phase::Connecting { .. } | Phase::Waiting { .. } => {
                        self.generation = self.generation.next();
                        self.phase = Phase::Connected {
                            transport: self.transport,
                            path: *path,
                            rtt_millis: *rtt_millis,
                        };
                        Ok(vec![Effect::PromoteStandby { generation: self.generation }])
                    }
                    Phase::Idle | Phase::MacOffline | Phase::Connected { .. } | Phase::SignedOut => {
                        Ok(vec![Effect::CloseStandby])
                    }
                }
            }
            Event::StandbyLost { generation } => {
                self.current_standby(*generation)?;
                Ok(self.drop_standby())
            }
            Event::DialFailed { generation, reason } => {
                self.current(*generation)?;
                let Phase::Connecting { attempt, .. } = self.phase else {
                    return Err(Refusal::NotConnecting);
                };
                // Presence said offline and a dial (`Open`) confirmed it: offline now, no retry
                // loop until presence brings the Mac back.
                if self.target.as_ref().is_some_and(|t| !t.is_online) {
                    self.generation = self.generation.next();
                    self.media = VideoMedia::Off;
                    self.phase = Phase::MacOffline;
                    return Ok(Vec::new());
                }
                // The first failure retries at once and says nothing.
                if attempt <= SILENT_RETRIES {
                    return Ok(self.dial(attempt.saturating_add(1), false));
                }
                Ok(self.wait(attempt, reason))
            }
            Event::LinkUpdated { generation, path, rtt_millis } => {
                self.current(*generation)?;
                let Phase::Connected { transport, rtt_millis: old_rtt, .. } = self.phase else {
                    return Err(Refusal::NotConnected);
                };
                self.phase = Phase::Connected { transport, path: *path, rtt_millis: rtt_millis.or(old_rtt) };
                Ok(Vec::new())
            }
            Event::MediaUpdated { generation, media } => {
                self.current(*generation)?;
                if !self.phase.is_connected() {
                    return Err(Refusal::NotConnected);
                }
                self.media = media.clone();
                Ok(Vec::new())
            }
            Event::LinkDropped { generation, .. } | Event::ProbeFailed { generation, .. } => {
                self.current(*generation)?;
                if !self.phase.is_connected() {
                    return Err(Refusal::NotConnected);
                }
                // The Mac is offline: nothing to dial until presence brings it back.
                if self.target.as_ref().is_some_and(|t| !t.is_online) {
                    return Ok(self.reset(Phase::MacOffline));
                }
                // An unanswered probe on a link that has not closed: keep it beside the redial.
                // In the background iOS may suspend the process under it, so it closes.
                if matches!(event, Event::ProbeFailed { .. }) && self.keeps_standby && !self.is_backgrounded {
                    let kept = self.generation;
                    let mut effects = self.drop_standby();
                    effects.push(Effect::KeepStandby);
                    effects.extend(self.dial(1, false));
                    self.standby = Some(kept);
                    return Ok(effects);
                }
                // Redial at once; a failure then takes the usual retry path.
                let mut effects = vec![Effect::Close];
                effects.extend(self.dial(1, false));
                Ok(effects)
            }
            Event::MacSignaled => match self.phase {
                Phase::Connected { .. } => Ok(vec![Effect::QuickProbe { generation: self.generation }]),
                // The Mac just came back: dial now, not at the end of the backoff.
                Phase::Waiting { attempt, .. } => Ok(self.dial(attempt.saturating_add(1), false)),
                // A dial in flight sent its offer to a host that was down or restarting.
                Phase::Connecting { attempt, .. } => Ok(self.dial(attempt, false)),
                Phase::Idle | Phase::MacOffline | Phase::SignedOut => Err(Refusal::NothingToDo),
            },
            Event::NetworkChanged => match self.phase {
                Phase::Waiting { attempt, .. } => Ok(self.dial(attempt.saturating_add(1), false)),
                // A dial on the dead path would wait out its whole timeout.
                Phase::Connecting { attempt, .. } => Ok(self.dial(attempt, false)),
                // A live link roams in place.
                Phase::Idle | Phase::MacOffline | Phase::Connected { .. } | Phase::SignedOut => {
                    Err(Refusal::NothingToDo)
                }
            },
            Event::RetryDue { generation } => {
                self.current(*generation)?;
                let Phase::Waiting { attempt, .. } = self.phase else {
                    return Err(Refusal::NotWaiting);
                };
                Ok(self.dial(attempt.saturating_add(1), false))
            }
            Event::Open => match self.phase {
                Phase::MacOffline => Ok(self.dial(1, false)),
                Phase::Waiting { attempt, .. } => Ok(self.dial(attempt.saturating_add(1), false)),
                Phase::Idle | Phase::Connecting { .. } | Phase::Connected { .. } | Phase::SignedOut => {
                    Err(Refusal::NothingToDo)
                }
            },
            Event::Foreground => match self.phase {
                Phase::Waiting { attempt, .. } => Ok(self.dial(attempt.saturating_add(1), false)),
                Phase::Connected { .. } => Ok(vec![Effect::Probe { generation: self.generation }]),
                Phase::Idle | Phase::MacOffline | Phase::Connecting { .. } | Phase::SignedOut => {
                    Err(Refusal::NothingToDo)
                }
            },
        }
    }

    fn current(&self, generation: Generation) -> Result<(), Refusal> {
        if generation == self.generation { Ok(()) } else { Err(Refusal::StaleGeneration) }
    }

    fn current_standby(&self, generation: Generation) -> Result<(), Refusal> {
        match self.standby {
            None => Err(Refusal::NoStandby),
            Some(kept) if kept == generation => Ok(()),
            Some(_) => Err(Refusal::StaleGeneration),
        }
    }

    /// Swift's `.target` arm. Always records the target, so never a refusal.
    fn retarget(&mut self, next: Option<&Target>) -> Vec<Effect> {
        let same_mac = next.map(|t| &t.mac_id) == self.target.as_ref().map(|t| &t.mac_id);
        self.target = next.cloned();
        let Some(next) = next else { return self.reset(Phase::Idle) };
        if !next.is_online {
            // Presence is signaling, the link is peer to peer: keep a live link and probe it.
            if same_mac && self.phase.is_connected() {
                return vec![Effect::QuickProbe { generation: self.generation }];
            }
            // A dial a surface asked for is left to finish.
            if same_mac && matches!(self.phase, Phase::Connecting { .. }) {
                return Vec::new();
            }
            return self.reset(Phase::MacOffline);
        }
        if same_mac && self.phase.is_active() {
            return Vec::new();
        }
        self.dial(1, true)
    }

    /// A setting changed: redial when `applies` and the target is online.
    fn redial_if_online(&mut self, applies: bool) -> Vec<Effect> {
        if applies && self.target.as_ref().is_some_and(|t| t.is_online) {
            self.dial(1, true)
        } else {
            Vec::new()
        }
    }

    fn reset(&mut self, next: Phase) -> Vec<Effect> {
        let was_active = self.phase.is_active();
        self.generation = self.generation.next();
        self.media = VideoMedia::Off;
        self.phase = next;
        self.standby = None;
        if was_active { vec![Effect::Close] } else { Vec::new() }
    }

    /// Forget the standby link; the effect that closes it, if there was one.
    fn drop_standby(&mut self) -> Vec<Effect> {
        if self.standby.take().is_some() { vec![Effect::CloseStandby] } else { Vec::new() }
    }

    fn dial(&mut self, attempt: u32, closing: bool) -> Vec<Effect> {
        let Some(target) = &self.target else { return Vec::new() };
        let mac_id = target.mac_id.clone();
        let was_active = self.phase.is_active();
        self.generation = self.generation.next();
        self.media = VideoMedia::Off;
        self.phase = Phase::Connecting { transport: self.transport, attempt };
        let dial = Effect::Dial { generation: self.generation, mac_id, transport: self.transport };
        if closing && was_active {
            // `Close` closes the standby link too.
            self.standby = None;
            vec![Effect::Close, dial]
        } else {
            vec![dial]
        }
    }

    fn wait(&mut self, attempt: u32, reason: &str) -> Vec<Effect> {
        self.generation = self.generation.next();
        self.media = VideoMedia::Off;
        let after = self.retry_delay(attempt);
        self.phase =
            Phase::Waiting { transport: self.transport, attempt, reason: reason.to_owned(), retry_in: after };
        vec![Effect::ScheduleRetry { generation: self.generation, after }]
    }

    /// `backoff[min(max(attempt - 1 - silentRetries, 0), count - 1)]`. Swift traps on an empty
    /// table; this waits zero.
    pub fn retry_delay(&self, attempt: u32) -> Duration {
        let index = attempt.saturating_sub(1).saturating_sub(SILENT_RETRIES) as usize;
        self.backoff.get(index).or(self.backoff.last()).copied().unwrap_or(Duration::ZERO)
    }
}
