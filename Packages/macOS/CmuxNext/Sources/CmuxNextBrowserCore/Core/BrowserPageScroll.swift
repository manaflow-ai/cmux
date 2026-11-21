/// A keyboard scroll of a browser page (Vimium's `j`, `k`, `gg`, `G`), as a script either engine
/// runs in an isolated world with no user gesture. It scrolls what the person sees scroll: the
/// document, or (an app page whose document does not scroll, such as a mail client) the
/// scrollable element around the focused one, else the largest one on screen.
public nonisolated enum BrowserPageScroll: Sendable, CaseIterable {
    /// One step down (`j`).
    case down
    /// One step up (`k`).
    case up
    /// The top (`gg`).
    case top
    /// The bottom (Shift-G).
    case bottom

    /// The catalog action that runs it (`browserScrollDown`, …).
    public var actionID: String {
        switch self {
        case .down: "browserScrollDown"
        case .up: "browserScrollUp"
        case .top: "browserScrollToTop"
        case .bottom: "browserScrollToBottom"
        }
    }

    /// Vimium's step, in CSS pixels: what a tap moves.
    static let step = 60

    /// A held `j` or `k` (user, 2026-11-17: "holding j/k to scroll doesn't feel intuitive"). The
    /// page's frame clock drives it, not the system's key repeat: one press starts it, it moves
    /// at ``holdSpeed`` from the first frame (no pause at the key-repeat delay, no 60px jumps per
    /// repeat), eases to a top speed (``topSpeed(keyRepeatInterval:)``, 1200px/s by default) after ``holdCruise`` (Vimium speeds up a held key the
    /// same way), and on key-up slows to a stop: it ends a tap's ``step`` when less has moved,
    /// else it brakes within about ``holdBrake`` × 2 (3 frames). Speeds are CSS px per second.
    static let holdSpeed = 600.0
    static let holdTopSpeed = 1200.0
    static let holdFastestSpeed = 2400.0
    static let holdCruise = 0.2
    static let holdRamp = 0.3
    static let holdBrake = 0.025
    /// A held key repeats (key-downs with `repeat`) at most this far apart (macOS's slowest
    /// initial key-repeat delay is 1.8 s): with none for longer, its key-up was lost (it went to
    /// another app, the page missed it) and the scroll ends instead of running on.
    static let holdQuiet = 2.5

    /// The page's global for the scroll that runs, in the isolated world (``release(_:)``).
    static let state = "__cmuxPageScroll"

    /// A held key's top speed for the person's key repeat (System Settings > Keyboard): what a
    /// held key moved before, one ``step`` per repeat, from 1200 up to 2400px/s, so a fast key
    /// repeat keeps its pace without the jumps.
    public static func topSpeed(keyRepeatInterval: Double) -> Double {
        guard keyRepeatInterval > 0 else { return holdTopSpeed }
        return min(holdFastestSpeed, max(holdTopSpeed, Double(step) / keyRepeatInterval))
    }

    /// The letter whose key-up ends a held scroll.
    public var letter: String? {
        switch self {
        case .down: "j"
        case .up: "k"
        case .top, .bottom: nil
        }
    }

    /// Ends the held scroll that `letter`'s key started (its key-up, which the page may have
    /// missed: the key went up before the start script ran, or another window had the key). A
    /// scroll another key started goes on.
    public static func release(_ letter: String) -> String {
        "(() => { const s = globalThis.\(state); if (s) s.release(\(jsString(letter))); return !!s; })()"
    }

    private static func jsString(_ text: String) -> String {
        "'" + text.filter { $0.isLetter }.prefix(1) + "'"
    }

    /// The script; it returns whether something scrolled. `j` and `k` start a held scroll the
    /// page's key-up ends (an instant step under Reduce Motion, one per key repeat, as before);
    /// top and bottom glide unless the person asked for reduced motion.
    public var script: String { script(topSpeed: Self.holdTopSpeed) }

    /// The script, with a held key's top speed (``topSpeed(keyRepeatInterval:)``).
    public func script(topSpeed: Double) -> String {
        let top = min(Self.holdFastestSpeed, max(Self.holdSpeed, topSpeed.isFinite ? topSpeed : Self.holdTopSpeed))
        let move = switch self {
        case .down: "return hold(1);"
        case .up: "return hold(-1);"
        case .top: "el.scrollTo({ top: 0, behavior: glide }); return true;"
        case .bottom: "el.scrollTo({ top: el.scrollHeight, behavior: glide }); return true;"
        }
        return """
        (() => {
          const room = (el) => el && el.scrollHeight - el.clientHeight > 4;
          const scrolls = (el) => {
            if (!room(el)) return false;
            const y = getComputedStyle(el).overflowY;
            return y === 'auto' || y === 'scroll' || y === 'overlay';
          };
          let el = document.scrollingElement || document.documentElement;
          if (!room(el) || getComputedStyle(document.body || el).overflowY === 'hidden' && !scrolls(el)) {
            let near = document.activeElement;
            while (near && near !== document.body && !scrolls(near)) near = near.parentElement;
            if (near && near !== document.body && scrolls(near)) {
              el = near;
            } else {
              let best = null, area = 0, seen = 0;
              for (const each of document.body ? document.body.getElementsByTagName('*') : []) {
                if (++seen > 5000) break;
                if (!scrolls(each)) continue;
                const box = each.getBoundingClientRect();
                const shown = Math.max(0, Math.min(box.right, innerWidth) - Math.max(box.left, 0))
                  * Math.max(0, Math.min(box.bottom, innerHeight) - Math.max(box.top, 0));
                if (shown > area) { area = shown; best = each; }
              }
              if (best) el = best;
            }
          }
          const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
          const glide = reduce ? 'auto' : 'smooth';
          const nudge = (dy) => {
            const before = el.scrollTop;
            // 'instant': a page's `scroll-behavior: smooth` would animate each nudge against the next.
            el.scrollBy({ top: dy, behavior: 'instant' });
            return el.scrollTop !== before;
          };
          const hold = (dir) => {
            if (reduce) return nudge(dir * \(Self.step));
            const key = \(Self.jsString(letter ?? ""));
            const running = globalThis.\(Self.state);
            // A key repeat of the key that runs it changes nothing: the frame clock drives it.
            if (running && running.dir === dir && running.key === key && !running.released) { running.alive(); return true; }
            if (running) running.cancel();
            const V0 = \(Self.holdSpeed), V1 = \(top), CRUISE = \(Self.holdCruise), RAMP = \(Self.holdRamp);
            const BRAKE = \(Self.holdBrake), STEP = \(Self.step), QUIET = \(Self.holdQuiet * 1000);
            // Speed and distance after t seconds held: V0, then a smoothstep to V1 over RAMP.
            const speed = (t) => {
              if (t <= CRUISE) return V0;
              const u = Math.min(1, (t - CRUISE) / RAMP);
              return V0 + (V1 - V0) * u * u * (3 - 2 * u);
            };
            const held = (t) => {
              if (t <= CRUISE) return V0 * t;
              const u = Math.min(1, (t - CRUISE) / RAMP);
              const ramp = RAMP * (V0 * u + (V1 - V0) * (u * u * u - u * u * u * u / 2));
              return V0 * CRUISE + ramp + V1 * Math.max(0, t - CRUISE - RAMP);
            };
            const t0 = performance.now();
            let applied = 0, frame = 0, stopAt = null, from = 0, v = 0, rest = 0, brake = 0;
            const at = (now) => {
              const t = Math.max(0, now - t0) / 1000;
              if (stopAt === null) return held(t);
              const s = Math.min(brake, t - stopAt);
              return from + v * s - v * s * s / (2 * brake);
            };
            const self = { dir, key, released: false };
            let heard = t0;
            self.alive = () => { heard = performance.now(); };
            const ends = { keyup: null, blur: null, visibilitychange: null, pagehide: null, wheel: null, mousedown: null, keydown: null };
            const off = () => {
              for (const type in ends) if (ends[type]) {
                (type === 'visibilitychange' ? document : window).removeEventListener(type, ends[type], { capture: true });
              }
            };
            self.cancel = () => {
              cancelAnimationFrame(frame);
              off();
              if (globalThis.\(Self.state) === self) delete globalThis.\(Self.state);
            };
            // Key-up: velocity-matched ease-out to a stop, a tap's step at least.
            self.release = (which) => {
              if (self.released || (which && which !== key)) return;
              self.released = true;
              const t = Math.max(0, performance.now() - t0) / 1000;
              from = held(t); v = speed(t); stopAt = t;
              rest = Math.max(STEP - from, v * BRAKE);
              brake = 2 * rest / v;
            };
            const tick = (now) => {
              if (!self.released && now - heard > QUIET) self.release(key);
              const target = Math.round(dir * at(now));
              const delta = target - applied;
              applied = target;
              const stuck = delta !== 0 && !nudge(delta);
              const done = stopAt !== null && Math.max(0, now - t0) / 1000 >= stopAt + brake;
              if (stuck || done) return self.cancel();
              frame = requestAnimationFrame(tick);
            };
            const mine = (event) => event && typeof event.key === 'string'
              && (event.key.toLowerCase() === key || event.code === 'Key' + key.toUpperCase());
            ends.keyup = (event) => { if (mine(event)) self.release(key); };
            ends.blur = () => self.release(key);
            ends.visibilitychange = () => { if (document.visibilityState !== 'visible') self.cancel(); };
            ends.pagehide = () => self.cancel();
            // The person takes over: the wheel, a click or another key stops it where it is.
            ends.wheel = () => self.cancel();
            ends.mousedown = () => self.cancel();
            ends.keydown = (event) => { if (mine(event)) self.alive(); else self.cancel(); };
            for (const type in ends) {
              (type === 'visibilitychange' ? document : window).addEventListener(type, ends[type], { capture: true, passive: true });
            }
            globalThis.\(Self.state) = self;
            frame = requestAnimationFrame(tick);
            return true;
          };
          \(move)
        })()
        """
    }
}
