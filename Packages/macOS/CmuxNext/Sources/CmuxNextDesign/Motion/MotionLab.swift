#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextDesignTokens
public import Foundation

/// MOTION LAB (cmux-ad m73, Lawrence: "i want to try all the different curves to see which one i prefer"): one in-memory
/// model of the close, zoom and pin motion a person tries live from Debug > Motion Lab. DEBUG and bench builds only, branch
/// motion-lab-nomerge only: never a PR, never merged. Each change applies to the next action, with no restart.
///
/// The film selectors stay the model the motion code reads (``DesignSettings/filmClose``, ``DesignSettings/filmZoom``,
/// seeded by `CMUX_FILM_CLOSE_*` / `CMUX_FILM_ZOOM_*` and set by `debug.frames close_variant` / `zoom_variant`), so the
/// film kits keep working; the lab seeds from them and writes them back (``apply()``). The pin curve is the
/// `motion.spring.move` tunable the pin flight, its rows and its glyph fade use. The one lab is
/// ``DesignSettings/motionLab``.
@MainActor public final class MotionLab {

    public enum Close: String, CaseIterable, Sendable {
        case v0 = "V0", v1 = "V1", v3 = "V3", v6 = "V6"
        public var title: String {
            switch self {
            case .v0: "V0 now"
            case .v1: "V1 instant"
            case .v3: "V3 slide out"
            case .v6: "V6 fade + grow"
            }
        }
    }

    public enum Zoom: String, CaseIterable, Sendable {
        case z0 = "Z0", z4 = "Z4"
        public var title: String { self == .z0 ? "Z0 now" : "Z4 grow + fade" }
    }

    public enum Pin: String, CaseIterable, Sendable {
        case p0 = "P0", p1 = "P1"
        public var title: String { self == .p0 ? "P0 now" : "P1 translate" }
    }

    public enum Curve: String, CaseIterable, Sendable {
        case cur = "CUR", k2 = "K2", k3 = "K3", k4 = "K4", k5 = "K5", k6 = "K6", k10 = "K10", k11 = "K11", k12 = "K12"

        public var title: String {
            switch self {
            case .cur: "CUR (current)"
            case .k2: "K2 ease-out 100"
            case .k3: "K3 ease-out 120"
            case .k4: "K4 quint 100"
            case .k5: "K5 ease-in-out 120"
            case .k6: "K6 spring 0.15 no bounce"
            case .k10: "K10 linear 100"
            case .k11: "K11 spring 0.12"
            case .k12: "K12 spring 0.2"
            }
        }

        /// The curve set's shape (``FilmCloseVariant/Shape/named``).
        public var shape: FilmCloseVariant.Shape { FilmCloseVariant.Shape.named[rawValue] ?? .spring(response: 0.15, damping: 1) }
        public var isSpring: Bool { if case .spring = shape { true } else { false } }
    }

    /// One motion's curve and time: `milliseconds` nil keeps the curve's own time (a bezier's duration, a spring's
    /// response); a value overrides it.
    public struct Track: Equatable, Sendable {
        public var curve: Curve
        public var milliseconds: Double?
        public init(curve: Curve, milliseconds: Double? = nil) {
            self.curve = curve
            self.milliseconds = milliseconds
        }
    }

    public var close: Close = .v0
    public var closeTrack = Track(curve: .cur)
    public var zoom: Zoom = .z0
    public var zoomTrack = Track(curve: .k2)
    public var pin: Pin = .p1
    public var pinTrack = Track(curve: .cur)
    /// Every lab motion's time times 4.
    public var slow = false
    /// The shared redraw hold (RESIZE P0 12/13): a new terminal size waits for the program's redraw at its grid, at most
    /// a few refreshes. Off: no size waits (for comparison).
    public var redrawHold = true

    private let store: TunableStore

    init(store: TunableStore = .shared) {
        self.store = store
    }

    /// Takes the film selectors' choices (the launch variables, `debug.frames`) as the lab's (the window's first show).
    func seed() {
        let film = DesignSettings.shared.filmClose
        close = Close(rawValue: film.kind.rawValue) ?? .v0
        closeTrack = Track(curve: film.named.flatMap(Curve.init(rawValue:)) ?? .cur)
        let zoomFilm = DesignSettings.shared.filmZoom
        zoom = zoomFilm.kind == .z4 ? .z4 : .z0
        zoomTrack = Track(curve: Curve(rawValue: zoomFilm.curve.rawValue) ?? .k2)
    }

    /// P1 plays (the pin flight); false plays P0, the path before it.
    public var pinFlies: Bool { pin == .p1 }

    /// The pin curve P1 plays: a spring (the flight is spring-only today); a bezier curve plays K6.
    public var pinSpringOnly: Bool { !pinTrack.curve.isSpring }

    /// `track`'s shape with the slider's time and the slow-motion factor; `current` is what CUR means for this motion.
    func shape(_ track: Track, current: FilmCloseVariant.Shape? = nil) -> FilmCloseVariant.Shape {
        let factor = slow ? 4.0 : 1.0
        switch track.curve == .cur ? current ?? track.curve.shape : track.curve.shape {
        case let .bezier(x1, y1, x2, y2, seconds):
            return .bezier(x1: x1, y1: y1, x2: x2, y2: y2, seconds: (track.milliseconds.map { $0 / 1000 } ?? seconds) * factor)
        case let .spring(response, damping):
            return .spring(response: (track.milliseconds.map { $0 / 1000 } ?? response) * factor, damping: damping)
        }
    }

    /// Whether `track` is the build's own motion, untouched.
    private func isCurrent(_ track: Track) -> Bool { track.curve == .cur && track.milliseconds == nil && !slow }

    /// Writes the choices where the motion code reads them; the next close, zoom or pin plays them.
    public func apply() {
        var film = DesignSettings.shared.filmClose
        film.kind = FilmCloseVariant.kind(close.rawValue) ?? .v0
        film.named = nil
        film.custom = close == .v0 && isCurrent(closeTrack) ? nil : shape(closeTrack)
        film.milliseconds = closeTrack.milliseconds ?? 150
        DesignSettings.shared.filmClose = film

        var zoomFilm = DesignSettings.shared.filmZoom
        zoomFilm.kind = zoom == .z4 ? .z4 : .v0
        zoomFilm.curve = FilmZoomVariant.curve(zoomTrack.curve.rawValue) ?? .cur
        // CUR for the zoom is its own spring (`MotionSpring.zoom`'s default: response 0.2, critically damped).
        switch isCurrent(zoomTrack) ? nil : shape(zoomTrack, current: .spring(response: 0.2, damping: 1)) {
        case nil: zoomFilm.custom = nil
        case let .bezier(x1, y1, x2, y2, seconds)?:
            zoomFilm.custom = .bezier(x1: Float(x1), y1: Float(y1), x2: Float(x2), y2: Float(y2), seconds: seconds)
        case let .spring(response, damping)?: zoomFilm.custom = .spring(damping: damping, response: response)
        }
        DesignSettings.shared.filmZoom = zoomFilm

        let key = "motion.spring.move"
        if pin == .p1, !isCurrent(pinTrack) {
            let track = pinSpringOnly ? Track(curve: .k6, milliseconds: pinTrack.milliseconds) : pinTrack
            // CUR for the pin is the move spring's default (response 0.15, critically damped).
            if case let .spring(response, damping) = shape(track, current: .spring(response: 0.15, damping: 1)) {
                _ = store.set(key, .spring(SpringParameters(response: response, dampingFraction: damping)))
            }
        } else {
            store.reset([key])
        }
    }

    /// The choices as one line ("close=V6 K6 150ms hold=on; zoom=Z4 K12 200ms; pin=P1 K6 150ms; slow=off").
    public var picks: String {
        func time(_ track: Track) -> String {
            var ms: Double
            switch track.curve.shape {
            case let .bezier(_, _, _, _, seconds): ms = seconds * 1000
            case let .spring(response, _): ms = response * 1000
            }
            if let override = track.milliseconds { ms = override }
            return "\(Int(ms.rounded()))ms"
        }
        let pinCurve = pin == .p1 && pinSpringOnly ? "K6(spring only, picked \(pinTrack.curve.rawValue))" : pinTrack.curve.rawValue
        return "close=\(close.rawValue) \(closeTrack.curve.rawValue) \(time(closeTrack)) hold=\(redrawHold ? "on" : "off"); "
            + "zoom=\(zoom.rawValue) \(zoomTrack.curve.rawValue) \(time(zoomTrack)); "
            + "pin=\(pin.rawValue) \(pinCurve) \(time(pinTrack)); slow=\(slow ? "on" : "off")"
    }
}
#endif
