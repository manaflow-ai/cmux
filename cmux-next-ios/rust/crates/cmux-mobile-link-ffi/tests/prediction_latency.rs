//! Keystroke-to-glyph latency of the phone's terminal, with and without
//! predictive local echo, over an emulated link (50, 150 and 300 ms round
//! trips, 0 %, 2 % and 5 % packet loss). The same harness drives both runs;
//! "before" is the same object with prediction off.
//!
//! The model, each piece as the phone sees it:
//! - typist: commands with typos fixed by Backspace, 90 to 190 ms between keys,
//!   Return after each, a `sudo` password typed blind, and a full-screen
//!   program (alternate screen) driven by keys;
//! - link: half the round trip each way with 10 % jitter; one stream in order,
//!   so a lost packet arrives a retransmit timeout later (max(200 ms, 2 RTT)) and
//!   holds every packet behind it (head-of-line blocking);
//! - remote: a line editor that echoes a printable key, erases with `BS SP BS`,
//!   prints the command's output and a new prompt on Return, echoes nothing at
//!   the password prompt, and redraws the screen in the full-screen program;
//! - phone: Ghostty parses output when it lands; a frame presents on each
//!   120 Hz display refresh.
//!
//! A key's latency is from the key press to the first frame showing its effect:
//! the predicted glyph (or its retraction) when the overlay draws it, else the
//! frame after its echo. Run with `--nocapture` for the table.

use cmux_mobile_link_ffi::{PredictionLayout, TerminalPrediction};

const MS: u64 = 1_000;
const FRAME_US: u64 = 8_333;
const COLUMNS: i32 = 80;
const PROMPT: &[u8] = b"$ ";

/// xorshift64*: reproducible runs with no dependency.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }
    fn between(&mut self, low: u64, high: u64) -> u64 {
        low + self.next() % (high - low + 1)
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Shell,
    Password,
    FullScreen,
}

enum Step {
    Keys(&'static [u8]),
    Backspaces(usize),
    Return,
}

/// One direction of the link: in order, lossy, with retransmits.
struct Pipe {
    one_way_us: u64,
    loss: f64,
    rto_us: u64,
    last_arrival: u64,
}

impl Pipe {
    fn arrival(&mut self, sent_at: u64, rng: &mut Rng) -> u64 {
        let jitter = (self.one_way_us as f64 * 0.1 * (rng.unit() * 2.0 - 1.0)) as i64;
        let mut at = sent_at + (self.one_way_us as i64 + jitter).max(0) as u64;
        while rng.unit() < self.loss {
            at += self.rto_us;
        }
        self.last_arrival = self.last_arrival.max(at);
        self.last_arrival
    }
}

/// What the remote does with one key, and the bytes it answers with.
struct Remote {
    mode: Mode,
    line: Vec<u8>,
}

impl Remote {
    fn receive(&mut self, key: &[u8]) -> Vec<u8> {
        match (self.mode, key) {
            (Mode::FullScreen, [b'q']) => {
                self.mode = Mode::Shell;
                let mut out = b"\x1b[?1049l".to_vec();
                out.extend_from_slice(PROMPT);
                out
            }
            // A full-screen program redraws its status line for any key.
            (Mode::FullScreen, _) => b"\x1b[24;1H\x1b[2Kselected row 3\x1b[1;1H".to_vec(),
            (Mode::Password, [b'\r']) => {
                self.mode = Mode::Shell;
                let mut out = b"\r\n".to_vec();
                out.extend_from_slice(PROMPT);
                out
            }
            (Mode::Password, _) => Vec::new(),
            (Mode::Shell, [b'\r']) => {
                let command = std::mem::take(&mut self.line);
                let mut out = b"\r\n".to_vec();
                if command.starts_with(b"sudo") {
                    self.mode = Mode::Password;
                    out.extend_from_slice(b"[sudo] password for leo: ");
                    return out;
                }
                if command.starts_with(b"htop") {
                    self.mode = Mode::FullScreen;
                    out.extend_from_slice(b"\x1b[?1049h\x1b[2J\x1b[1;1H  PID USER  CPU%\x1b[1;1H");
                    return out;
                }
                out.extend_from_slice(b"output line one\r\noutput line two\r\n");
                out.extend_from_slice(PROMPT);
                out
            }
            (Mode::Shell, [0x7F]) => {
                if self.line.pop().is_some() {
                    b"\x08 \x08".to_vec()
                } else {
                    b"\x07".to_vec()
                }
            }
            (Mode::Shell, [byte @ 0x20..=0x7E]) => {
                self.line.push(*byte);
                vec![*byte]
            }
            _ => Vec::new(),
        }
    }
}

/// The phone's view of the screen: enough to place the overlay.
struct Screen {
    cursor_column: i32,
    alternate: bool,
}

impl Screen {
    fn parse(&mut self, bytes: &[u8]) {
        let mut index = 0;
        while index < bytes.len() {
            match bytes[index] {
                b'\r' => self.cursor_column = 0,
                0x08 => self.cursor_column = (self.cursor_column - 1).max(0),
                0x1B => {
                    let start = index;
                    index += 1;
                    if bytes.get(index) == Some(&b'[') {
                        index += 1;
                        while index < bytes.len() && !(0x40..=0x7E).contains(&bytes[index]) {
                            index += 1;
                        }
                        let sequence = &bytes[start..=index.min(bytes.len() - 1)];
                        if sequence.ends_with(b"?1049h") {
                            self.alternate = true;
                        } else if sequence.ends_with(b"?1049l") {
                            self.alternate = false;
                        } else if sequence.ends_with(b"H") {
                            self.cursor_column = 0;
                        }
                    }
                }
                0x20..=0x7E => self.cursor_column = (self.cursor_column + 1).min(COLUMNS - 1),
                _ => {}
            }
            index += 1;
        }
    }
}

enum Event {
    /// The key at this index reaches the remote.
    KeyArrives(usize),
    /// Output for the key at this index reaches the phone.
    OutputArrives(usize, Vec<u8>, Mode),
}

struct Key {
    bytes: Vec<u8>,
    typed_at: u64,
    /// The frame showing its effect.
    shown_at: Option<u64>,
    /// Typed where the remote echoes it (the shell, not a password or a
    /// full-screen program): the keys a person waits on.
    echoed: bool,
}

struct Run {
    latencies: Vec<u64>,
    /// Glyphs drawn while the remote was at a password prompt or in a
    /// full-screen program (must be zero).
    drawn_where_unsafe: usize,
    /// Keys whose glyph showed before its echo.
    predicted: usize,
}

fn next_frame(at: u64) -> u64 {
    at.div_ceil(FRAME_US) * FRAME_US
}

fn script() -> Vec<Step> {
    vec![
        Step::Keys(b"git status"),
        Step::Return,
        Step::Keys(b"ls -la ~/Projects/cmux"),
        Step::Return,
        Step::Keys(b"echo hello wrold"),
        Step::Backspaces(4),
        Step::Keys(b"orld"),
        Step::Return,
        Step::Keys(b"sudo true"),
        Step::Return,
        Step::Keys(b"hunter2hunter2"),
        Step::Return,
        Step::Keys(b"htop"),
        Step::Return,
        Step::Keys(b"jjjkq"),
        Step::Keys(b"cargo test -p cmux-terminal-prediction"),
        Step::Backspaces(10),
        Step::Keys(b"prediction"),
        Step::Return,
        Step::Keys(b"cd ~/Projects && git log --oneline -5"),
        Step::Return,
    ]
}

fn layout_signature(layout: &Option<PredictionLayout>) -> Vec<(u8, u8, i32)> {
    layout
        .as_ref()
        .map(|layout| {
            layout.glyphs.iter().map(|glyph| (glyph.character, glyph.standing, glyph.offset)).collect()
        })
        .unwrap_or_default()
}

fn run(rtt_ms: u64, loss: f64, predict: bool, seed: u64) -> Run {
    let mut rng = Rng(seed);
    let rtt = rtt_ms * MS;
    let rto = (2 * rtt).max(200 * MS);
    let mut up = Pipe { one_way_us: rtt / 2, loss, rto_us: rto, last_arrival: 0 };
    let mut down = Pipe { one_way_us: rtt / 2, loss, rto_us: rto, last_arrival: 0 };
    let prediction = TerminalPrediction::new(predict, true);
    let mut remote = Remote { mode: Mode::Shell, line: Vec::new() };
    let mut screen = Screen { cursor_column: PROMPT.len() as i32, alternate: false };

    // The typist's keys and when each is pressed. A person waits for a
    // command's output before typing the next one.
    let mut keys: Vec<Key> = Vec::new();
    let mut steps: Vec<Vec<u8>> = Vec::new();
    for step in script() {
        match step {
            Step::Keys(text) => steps.extend(text.iter().map(|byte| vec![*byte])),
            Step::Backspaces(count) => steps.extend(std::iter::repeat_n(vec![0x7F], count)),
            Step::Return => steps.push(vec![b'\r']),
        }
    }

    let mut events: Vec<(u64, Event)> = Vec::new();
    let mut now = 0u64;
    let mut next_key = 0usize;
    let mut next_key_at = 0u64;
    let mut waiting_for_output_of: Option<usize> = None;
    let mut last_frame = 0u64;
    let mut drawn_where_unsafe = 0;
    // The remote's mode as of the newest output the phone has received: a
    // glyph drawn for a command still in flight when its Return reached the
    // remote is not drawn at the prompt that command opens.
    let mut phone_sees = Mode::Shell;

    loop {
        let next_event_at = events.iter().map(|(at, _)| *at).min();
        let key_due = next_key < steps.len() && waiting_for_output_of.is_none();
        let next_frame_at = next_frame(now + 1);
        let candidates = [next_event_at, key_due.then_some(next_key_at), Some(next_frame_at)];
        let at = candidates.into_iter().flatten().min().expect("a frame is always due");
        if next_key >= steps.len() && events.is_empty() && waiting_for_output_of.is_none() {
            break;
        }
        now = at;

        if key_due && next_key_at == now {
            let bytes = steps[next_key].clone();
            let before = layout_signature(&prediction.layout(now, screen.cursor_column, COLUMNS));
            prediction.sent(bytes.clone(), now);
            let after = layout_signature(&prediction.layout(now, screen.cursor_column, COLUMNS));
            let index = keys.len();
            let echoed = remote.mode == Mode::Shell && bytes != [b'\r'];
            let shown_at = (before != after && echoed).then(|| next_frame(now));
            keys.push(Key { bytes: bytes.clone(), typed_at: now, shown_at, echoed });
            events.push((up.arrival(now, &mut rng), Event::KeyArrives(index)));
            if bytes == [b'\r'] {
                waiting_for_output_of = Some(index);
            }
            next_key += 1;
            next_key_at = now + rng.between(90, 190) * MS;
            continue;
        }

        if let Some(position) = events.iter().position(|(event_at, _)| *event_at == now) {
            // `remove`, not `swap_remove`: ties (packets held behind one loss)
            // keep the order they were sent in.
            let (_, event) = events.remove(position);
            match event {
                Event::KeyArrives(index) => {
                    let answer = remote.receive(&keys[index].bytes);
                    // Even no echo answers in time: the phone learns nothing, but
                    // a key typed after Return at a password prompt has to wait.
                    let arrives = down.arrival(now + 500, &mut rng);
                    events.push((arrives, Event::OutputArrives(index, answer, remote.mode)));
                }
                Event::OutputArrives(index, bytes, mode) => {
                    // The phone learns the remote's mode with the output that changed it.
                    phone_sees = mode;
                    if !bytes.is_empty() {
                        prediction.output(bytes.clone(), now);
                        screen.parse(&bytes);
                    }
                    let key = &mut keys[index];
                    if key.shown_at.is_none() {
                        key.shown_at = Some(next_frame(now));
                    }
                    if waiting_for_output_of == Some(index) {
                        waiting_for_output_of = None;
                        next_key_at = now + rng.between(400, 900) * MS;
                    }
                }
            }
            continue;
        }

        // A display refresh.
        if now != last_frame {
            last_frame = now;
            prediction.presented_frame(now);
            let layout = prediction.layout(now, screen.cursor_column, COLUMNS);
            let drawn = layout
                .map(|layout| layout.glyphs.iter().filter(|glyph| glyph.standing == 0).count())
                .unwrap_or(0);
            if phone_sees != Mode::Shell || screen.alternate {
                if drawn > 0 && drawn_where_unsafe == 0 {
                    let typed: Vec<String> = keys
                        .iter()
                        .rev()
                        .take(6)
                        .map(|key| format!("{:?}", String::from_utf8_lossy(&key.bytes)))
                        .collect();
                    eprintln!(
                        "UNSAFE rtt={rtt_ms} seed={seed} remote_password={} remote_full={} phone_alt={} status={} last_keys={typed:?} layout={:?}",
                        phone_sees == Mode::Password,
                        phone_sees == Mode::FullScreen,
                        screen.alternate,
                        prediction.status(now),
                        prediction.layout(now, screen.cursor_column, COLUMNS),
                    );
                }
                drawn_where_unsafe += drawn;
            }
        }
    }

    let mut latencies = Vec::new();
    let mut predicted = 0;
    for key in keys.iter().filter(|key| key.echoed) {
        let shown = key.shown_at.expect("every key is shown");
        let latency = shown - key.typed_at;
        if latency < rtt / 2 {
            predicted += 1;
        }
        latencies.push(latency);
    }
    Run { latencies, drawn_where_unsafe, predicted }
}

fn percentile(sorted: &[u64], fraction: f64) -> u64 {
    let index = ((sorted.len() as f64 - 1.0) * fraction).round() as usize;
    sorted[index]
}

fn summary(rtt_ms: u64, loss: f64, predict: bool) -> (Vec<u64>, usize, usize, usize) {
    let mut all = Vec::new();
    let mut unsafe_glyphs = 0;
    let mut predicted = 0;
    let mut keys = 0;
    for seed in 1..=20u64 {
        let run = run(rtt_ms, loss, predict, seed.wrapping_mul(0x9E37_79B9_7F4A_7C15));
        keys += run.latencies.len();
        all.extend(run.latencies);
        unsafe_glyphs += run.drawn_where_unsafe;
        predicted += run.predicted;
    }
    all.sort_unstable();
    (all, unsafe_glyphs, predicted, keys)
}

#[test]
fn keystroke_to_glyph_latency() {
    println!(
        "| RTT | loss | p50 before | p50 after | p95 before | p95 after | p99 before | p99 after | keys shown before echo |"
    );
    println!("|---|---|---|---|---|---|---|---|---|");
    let mut failures: Vec<String> = Vec::new();
    for rtt_ms in [50u64, 150, 300] {
        for loss in [0.0, 0.02, 0.05] {
            let (before, before_unsafe, _, _) = summary(rtt_ms, loss, false);
            let (after, after_unsafe, predicted, keys) = summary(rtt_ms, loss, true);
            assert_eq!(before_unsafe, 0);
            assert_eq!(after_unsafe, 0, "a glyph was drawn at a password prompt or in a full-screen program");
            let ms = |us: u64| us as f64 / 1000.0;
            println!(
                "| {rtt_ms} ms | {:.0} % | {:.1} | {:.1} | {:.1} | {:.1} | {:.1} | {:.1} | {}/{} |",
                loss * 100.0,
                ms(percentile(&before, 0.5)),
                ms(percentile(&after, 0.5)),
                ms(percentile(&before, 0.95)),
                ms(percentile(&after, 0.95)),
                ms(percentile(&before, 0.99)),
                ms(percentile(&after, 0.99)),
                predicted,
                keys,
            );
            // Prediction never makes a key slower, and on a clean 150 ms link
            // it shows most keys within two frames. A lost packet holds every
            // echo behind it for a retransmit, which ends the echo run, so the
            // bound there is only "never slower". At 300 ms the engine tracks
            // under half the keys (the untracked window after a barrier slides
            // with each key typed inside it; reported on #38449), so that row
            // is reported, not bounded, until the engine changes.
            if percentile(&after, 0.5) > percentile(&before, 0.5)
                || percentile(&after, 0.95) > percentile(&before, 0.95)
            {
                failures.push(format!("{rtt_ms} ms {loss}: slower with prediction"));
            }
            if rtt_ms == 150 && loss == 0.0 && percentile(&after, 0.5) > 2 * FRAME_US {
                failures.push(format!("{rtt_ms} ms: p50 after {} us", percentile(&after, 0.5)));
            }
        }
    }
    assert!(failures.is_empty(), "{failures:?}");
}
