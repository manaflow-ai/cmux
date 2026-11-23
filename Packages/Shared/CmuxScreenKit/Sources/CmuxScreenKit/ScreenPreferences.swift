import CmuxVNCWebRTC
import Foundation

/// A session's view choices, worth keeping per computer (Codable). Decoding
/// tolerates missing keys, so preferences saved by older builds keep loading.
public struct ScreenPreferences: Codable, Hashable, Sendable {
    /// Draw the remote cursor shape locally (RFB; no round trip for pointer motion).
    public var localCursor = true
    /// The live stats line under the title.
    public var showStats = true
    /// Fitted mode: pinned to one display; zoom out stops at that display's
    /// fit, panning stays inside it, and swipes at fit change display.
    public var fitToDisplay = true
    /// Screen stream quality (Auto lets WebRTC choose).
    public var quality = ScreenQuality.auto
    /// How touches drive the pointer: where the finger is (direct, the
    /// default) or a cursor moved like a laptop trackpad.
    public var inputMode = ScreenInputMode.direct
    /// The trackpad under the screen is up (the default): dragging its notch
    /// down tucks it away to a strip and gives the screen the room, dragging
    /// it up brings it back. Remembered with the rest; landscape starts tucked away.
    public var showTrackpad = true
    /// Customize: the highest bitrate the stream may use, in kbit/s (nil: Auto, the host's own
    /// cap). A cmux.rd host takes it as the offer's `a=cmux-rd-max-kbps`.
    public var maxKbps: Int?
    /// Customize: the stream shows the cursor (the default). Off, a cmux.rd host leaves it out
    /// of the stream altogether (`a=cmux-rd-cursor:0`).
    public var showCursorInStream = true

    /// The bitrate caps the Customize menu offers, in kbit/s (nil is Auto).
    public static let maxKbpsChoices: [Int?] = [nil, 2_000, 5_000, 10_000, 20_000]

    public init(localCursor: Bool = true, showStats: Bool = true, fitToDisplay: Bool = true, quality: ScreenQuality = .auto,
                inputMode: ScreenInputMode = .direct, showTrackpad: Bool = true, maxKbps: Int? = nil,
                showCursorInStream: Bool = true) {
        self.localCursor = localCursor
        self.showStats = showStats
        self.fitToDisplay = fitToDisplay
        self.quality = quality
        self.inputMode = inputMode
        self.showTrackpad = showTrackpad
        self.maxKbps = maxKbps
        self.showCursorInStream = showCursorInStream
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        localCursor = try container.decodeIfPresent(Bool.self, forKey: .localCursor) ?? true
        showStats = try container.decodeIfPresent(Bool.self, forKey: .showStats) ?? true
        fitToDisplay = try container.decodeIfPresent(Bool.self, forKey: .fitToDisplay) ?? true
        quality = (try? container.decodeIfPresent(ScreenQuality.self, forKey: .quality)) ?? .auto
        inputMode = (try? container.decodeIfPresent(ScreenInputMode.self, forKey: .inputMode)) ?? .direct
        showTrackpad = try container.decodeIfPresent(Bool.self, forKey: .showTrackpad) ?? true
        maxKbps = try? container.decodeIfPresent(Int.self, forKey: .maxKbps)
        showCursorInStream = try container.decodeIfPresent(Bool.self, forKey: .showCursorInStream) ?? true
    }
}

/// How touches drive the remote pointer (`ScreenPreferences.inputMode`).
/// - `direct`: a tap clicks where the finger is, press-and-hold then drag
///   drags, one finger pans a zoomed view.
/// - `trackpad`: a cursor that one finger moves relatively (faster strokes go
///   further); a tap clicks at the cursor, tap then hold and drag (or a long
///   press) drags, and a zoomed view follows the cursor.
///
/// Both: two-finger tap right-clicks, two fingers scroll, pinch zooms.
public enum ScreenInputMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case direct, trackpad

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .direct: "Direct Touch"
        case .trackpad: "Trackpad"
        }
    }

    /// An SF Symbol for the choice.
    public var symbol: String {
        switch self {
        case .direct: "hand.point.up.left"
        case .trackpad: "rectangle.and.hand.point.up.left"
        }
    }
}

/// Which orientations a session may use. `ScreenOrientation` (CmuxScreenKitUI)
/// applies it; `saved` remembers the user's choice across sessions.
public enum OrientationLock: String, CaseIterable, Identifiable, Sendable {
    case auto, portrait, landscape

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: "Auto-Rotate"
        case .portrait: "Portrait"
        case .landscape: "Landscape"
        }
    }

    /// An SF Symbol for the choice.
    public var symbol: String {
        switch self {
        case .auto: "arrow.trianglehead.2.clockwise.rotate.90"
        case .portrait: "iphone"
        case .landscape: "iphone.landscape"
        }
    }

    private static let key = "cmux.vnc.orientationLock"

    /// The last choice, in the app's standard user defaults.
    public static var saved: OrientationLock {
        get { UserDefaults.standard.string(forKey: key).flatMap(OrientationLock.init(rawValue:)) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
