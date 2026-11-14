import CmuxNextSettings
public import Foundation

/// Session Info drawn by the App (Leo, 2026-10-29: "plus we're gonna be doing that part natively in
/// swift anyways?"). The page still reads the chat and works out what each section lists; it sends
/// that as `pane.sessionInfo {info}` (webviews `session-info/native/model.ts`, `NativeSessionInfo`) and
/// draws no panel of its own. ``AgentPaneSessionInfoPanel`` draws it over the pane. A click on a row
/// or button goes back to the page as `sessionInfoAction {id}`, which runs what the page registered
/// for that id. Text, SF Symbol names and ids only: the App interprets none of it.
public nonisolated struct AgentPaneSessionInfoModel: Codable, Equatable, Sendable {
    public enum Tone: String, Codable, Sendable { case running, waiting, failed, done, muted, accent }

    public struct Button: Codable, Equatable, Sendable {
        public var label: String
        public var symbol: String?
        public var action: String
        public var disabled: Bool?
    }

    public struct Segment: Codable, Equatable, Sendable {
        public var share: Double
        public var color: String
    }

    /// The page's shared running-wave phase and cadence. Swift consumes these values; it does not
    /// choose a speed or index, so web and native rows stay in phase.
    public struct Wave: Codable, Equatable, Sendable {
        public var index: Int
        public var periodMs: Int
        public var stepMs: Int
    }

    public struct Hover: Codable, Equatable, Sendable {
        public var title: String
        public var detail: String?
    }

    public struct Row: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var symbol: String?
        public var symbolColor: String?
        public var harness: String?
        /// Identity ink selected by shared web, independent of the row's status.
        public var identityTone: Int?
        /// A retrying row uses the native spinner instead of its harness glyph.
        public var working: Bool?
        /// A running row's shared wave phase and cadence.
        public var wave: Wave?
        public var title: String
        public var detail: String?
        public var subtitle: String?
        /// Counts and queued/failed progress text supplied by the page.
        public var progress: String?
        public var trailing: String?
        public var tone: Tone?
        /// CSS can carry fractional indentation; the native row rounds it to a bounded level.
        public var indent: Double?
        public var meter: Double?
        public var action: String?
        public var buttons: [Button]?
        public var menu: [Button]?
        public var menuLabel: String?
        public var segments: [Segment]?
        public var hover: Hover?
        public var help: String?
        /// A native switch row. The page keeps the policy and sends the action id when the
        /// person changes it; the App only reflects the current value.
        public var toggle: Bool?
        public var marks: [Tone]?
    }

    public struct More: Codable, Equatable, Sendable {
        public var label: String
        public var action: String
    }

    public struct Section: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var group: String
        public var title: String
        public var symbol: String?
        public var meta: String?
        public var metaTone: Tone?
        public var meter: Double?
        public var segments: [Segment]?
        public var bare: Bool?
        public var open: Bool
        public var foldable: Bool
        public var rows: [Row]
        public var more: More?
        /// When true the section can be reordered by dragging its grip. The page owns
        /// validation and persistence; the App sends `move:<section>:<before|end>`.
        public var reorderable: Bool?
        public var reorderLabel: String?
    }

    /// The panel shows (its header toggle is on and nothing took the pane).
    public var open: Bool
    /// Its width, CSS pixels.
    public var width: Double
    /// Where it starts below the pane's top, CSS pixels: under the header or the shared tab row.
    public var top: Double
    /// Its distance from the pane's right edge, CSS pixels: a side panel's width beside the chat.
    public var side: Double
    /// Over the chat's column, how far above the pane's foot it stops (the composer's stack), CSS
    /// pixels; nil runs it to the foot less the float margin.
    public var foot: Double?
    /// It lies over the chat's column, a short pane's popover too (which sends no ``foot``): it gets
    /// the overlay glass under it, so the transcript never shows through it. Pages that predate it
    /// send only ``foot``.
    public var overChat: Bool?
    /// The panel's accessible name ("Session Info", in the page's language).
    public var label: String
    /// A subagent's own panel names the subagent at its top.
    public var title: String?
    /// A subagent panel's breadcrumb action. Chat panels leave this nil, so no title row appears.
    public var back: String?
    /// Localized label for the breadcrumb action.
    public var backLabel: String?
    /// A page-owned reveal request. The native view scrolls to the section and briefly highlights it.
    public var reveal: Reveal?
    public var sections: [Section]

    public struct Reveal: Codable, Equatable, Sendable {
        public var section: String
        /// A page revision may be fractional while a browser layout is settling; native rounds it
        /// only when comparing reveal requests.
        public var at: Double
    }

    /// The page's `info`, nil when it is not a model this App draws (a bad field, a width out of range).
    static func decode(_ value: Any?) -> AgentPaneSessionInfoModel? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let info = try? JSONDecoder().decode(AgentPaneSessionInfoModel.self, from: data),
              info.width.isFinite, (0...4000).contains(info.width),
              info.top.isFinite, (0...4000).contains(info.top),
              info.side.isFinite, (0...8000).contains(info.side),
              info.foot.map({ $0.isFinite && (0...4000).contains($0) }) ?? true,
              info.reveal.map({ $0.at.isFinite && $0.at >= 0 && $0.at <= Double(Int.max) }) ?? true else { return nil }
        return info
    }
}

/// A chat's natively drawn Session Info: the last model its page sent and the panel that draws it.
/// Kept on the model: ``AgentPaneView`` is at its size limit.
@MainActor public final class AgentPaneSessionInfo {
    /// What the page last sent; nil while it sends none (an older page, the setting off, no chat).
    public private(set) var info: AgentPaneSessionInfoModel?
    /// The panel while one is made (AgentPaneView+SessionInfo.swift).
    var panel: AgentPaneSessionInfoPanel?
    /// Called when ``info`` changes: the view draws it.
    var onChange: (() -> Void)?
    /// Follows the Debug Settings toggle while the view lives (AgentPaneView+SessionInfo.swift).
    var hostObservation: Task<Void, Never>?
    /// What the loaded page was last told about the App drawing it (nil before the first load).
    var announced: Bool?

    /// The page's open popups the panel steps behind (`pane.sessionInfo.overlays`).
    public private(set) var overlays: [AgentPaneSessionInfoOverlay] = []
    /// Called when ``overlays`` changes: the view cuts them out of the panel.
    var onOverlays: (() -> Void)?

    /// The page's trackpad pinch (`pane.sessionInfo.pinch`): the panel zooms and pans with it.
    public private(set) var pinch = AgentPaneSessionInfoPinch.none
    /// Called when ``pinch`` changes: the view lays the panel out again.
    var onPinch: (() -> Void)?

    /// Whether the panel shows.
    public var isOpen: Bool { info?.open == true }

    func update(_ next: AgentPaneSessionInfoModel?) {
        guard next != info else { return }
        info = next
        onChange?()
    }

    func updateOverlays(_ next: [AgentPaneSessionInfoOverlay]) {
        guard next != overlays else { return }
        overlays = next
        onOverlays?()
    }

    func updatePinch(_ next: AgentPaneSessionInfoPinch) {
        guard next != pinch else { return }
        pinch = next
        onPinch?()
    }

    /// The page loaded again: it has sent nothing yet.
    func pageLoaded() {
        updatePinch(.none)
        updateOverlays([])
        update(nil)
    }
}

/// One of the page's open popups (a menu, a popover, the context ring's hover card) where the App's
/// Session Info panel floats: its box in the page's viewport, CSS pixels, and its corner radius. The
/// panel draws nothing and takes no clicks there, so the popup the page draws under it shows whole
/// (Leo, 2026-11-02: "layering issue the context should go over top of the session info").
public nonisolated struct AgentPaneSessionInfoOverlay: Equatable, Sendable {
    public var rect: CGRect
    public var radius: CGFloat
    /// View points per CSS pixel when the page measured it (webviews ui/visualViewportBox.ts
    /// `pageZoom`); nil from an older page, which is drawn at the pane's zoom now.
    public var zoom: CGFloat?

    public init(rect: CGRect, radius: CGFloat = 0, zoom: CGFloat? = nil) {
        self.rect = rect
        self.radius = radius
        self.zoom = zoom
    }

    /// A box's `zoom`: absent is nil, a number in range is that zoom, anything else is refused.
    static func decodeZoom(_ value: Any?) -> CGFloat?? {
        guard let value else { return .some(nil) }
        guard let zoom = (value as? NSNumber)?.doubleValue, zoom.isFinite, (0.05...20).contains(zoom) else { return nil }
        return .some(CGFloat(zoom))
    }

    /// The most a report carries (the page's `OVERLAY_RECTS_MAX`).
    static let maximum = 16

    /// `[{left, top, right, bottom, radius?, zoom?}]`, or nil for anything else (a bad number, too many).
    static func decode(_ value: Any?) -> [AgentPaneSessionInfoOverlay]? {
        guard let list = value as? [Any], list.count <= maximum else { return nil }
        var rects: [AgentPaneSessionInfoOverlay] = []
        for item in list {
            guard let box = item as? [String: Any] else { return nil }
            let number = { (key: String) -> Double? in
                guard let value = (box[key] as? NSNumber)?.doubleValue, value.isFinite, abs(value) <= 100_000 else {
                    return nil
                }
                return value
            }
            guard let left = number("left"), let top = number("top"), let right = number("right"),
                  let bottom = number("bottom"), right >= left, bottom >= top else { return nil }
            let radius = box["radius"] == nil ? 0 : number("radius")
            guard let radius, radius >= 0, let zoom = decodeZoom(box["zoom"]) else { return nil }
            rects.append(AgentPaneSessionInfoOverlay(
                rect: CGRect(x: left, y: top, width: right - left, height: bottom - top), radius: CGFloat(radius), zoom: zoom
            ))
        }
        return rects
    }
}

/// The page's trackpad pinch (Leo, 2026-11-12: "evidently you zoom in and it doesn't really, you know,
/// it doesn't follow"). A pinch in a Chromium page zooms its visual viewport only: the page's content
/// is scaled by `scale` and panned so that the layout point (`left`, `top`) (CSS pixels) shows at the
/// page's top left. The page's numbers for the panel (`top`, `side`, `width`) are layout pixels, so
/// the App's panel stayed where it was, at its size, over the zoomed page. The App maps the panel
/// through the same scale and offset and draws it magnified, so it zooms and pans with the page.
public nonisolated struct AgentPaneSessionInfoPinch: Equatable, Sendable {
    public var scale: CGFloat
    public var left: CGFloat
    public var top: CGFloat

    public init(scale: CGFloat, left: CGFloat = 0, top: CGFloat = 0) {
        self.scale = scale
        self.left = left
        self.top = top
    }

    /// No pinch: the page shows at its layout size and place.
    public static let none = AgentPaneSessionInfoPinch(scale: 1)

    /// A point in the page's layout (CSS pixels) where it shows under the pinch (CSS pixels of the
    /// unzoomed viewport): ui/visualViewportBox.ts `onVisualViewport`.
    func shown(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - left) * scale, y: (point.y - top) * scale)
    }

    /// The inverse of ``shown(_:)``: where a point on the zoomed screen lies in the page's layout.
    func layout(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / scale + left, y: point.y / scale + top)
    }

    /// `{scale, left, top}`, or nil for anything else (a bad number, a scale out of Chromium's range).
    static func decode(_ params: [String: Any]?) -> AgentPaneSessionInfoPinch? {
        guard let params else { return nil }
        let number = { (key: String) -> Double? in
            guard let value = (params[key] as? NSNumber)?.doubleValue, value.isFinite, abs(value) <= 100_000 else {
                return nil
            }
            return value
        }
        guard let scale = number("scale"), (0.1...20).contains(scale),
              let left = number("left"), let top = number("top") else { return nil }
        return AgentPaneSessionInfoPinch(scale: CGFloat(scale), left: CGFloat(left), top: CGFloat(top))
    }
}

extension AgentPageEvent {
    /// The App draws Session Info for this page (`sessionInfoHost`): the page sends its model and
    /// draws no panel of its own.
    static func sessionInfoHost(_ on: Bool) -> AgentPageEvent { AgentPageEvent(kind: "sessionInfoHost", value: .bool(on)) }
    /// The person clicked a row or button the page named `id`, or `action` is one of the panel's own:
    /// `width:<css px>` (a drag of its edge ended), `fold:<section>:<0|1>`, `close`.
    static func sessionInfoAction(_ id: String, rect: CGRect? = nil) -> AgentPageEvent {
        guard let rect else { return AgentPageEvent(kind: "sessionInfoAction", value: .string(id)) }
        return AgentPageEvent(kind: "sessionInfoAction", value: .object([
            "id": .string(id),
            "rect": .object([
                "left": .number(Double(rect.minX)), "top": .number(Double(rect.minY)),
                "right": .number(Double(rect.maxX)), "bottom": .number(Double(rect.maxY)),
            ]),
        ]))
    }
}

extension AgentPaneSessionInfo {
    /// The old host's script for ``AgentPageEvent/sessionInfoHost(_:)``.
    static func hostScript(_ on: Bool) -> String { "window.cmuxAcpmuxSessionInfo?.host?.(\(on));" }
    /// The old host's script for ``AgentPageEvent/sessionInfoAction(_:)``.
    static func actionScript(_ id: String, rect: CGRect? = nil) -> String {
        let value: JSONValue = rect.map {
            .object([
                "id": .string(id),
                "rect": .object([
                    "left": .number(Double($0.minX)), "top": .number(Double($0.minY)),
                    "right": .number(Double($0.maxX)), "bottom": .number(Double($0.maxY)),
                ]),
            ])
        } ?? .string(id)
        return "window.cmuxAcpmuxSessionInfo?.action?.(\(value.compactText));"
    }
}
