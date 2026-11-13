// SPDX-License-Identifier: GPL-3.0-or-later
public import AppKit
public import CmuxNextComputerUse

/// What the live preview reads from the App: the setting and the surface the person looks at. The App conforms (AppServices); tests can stand in.
@MainActor
public protocol ComputerUsePreviewHost: AnyObject {
    /// `computerUse.livePreview` now.
    var computerUseLivePreviewEnabled: Bool { get }
    /// The surface the person looks at (the focused tab of the key window's shown workspace, while
    /// cmux is the active app), with the view the preview docks over; nil when it is no agent's.
    func computerUsePreviewFocus() -> (surface: ComputerUsePreviewSurface, host: NSView)?
}

/// What a preview may show now, from its stream's events (pure: tests feed it a real stream's
/// events). A still shows until the video's first frame is in the layer; `blocked`, `no_window`
/// (the window closed), a closed channel and another window (`windowChanged`) take every picture away, and nothing shows again
/// until a new frame or still comes.
public struct ComputerUsePreviewPicture: Equatable {
    /// The stream said its window's app is private: nothing shows until it says `streaming` or
    /// `still` again (the channel stays open; cmux Remote looks every 500 ms).
    public private(set) var blocked = false
    /// A picture (a video frame or a still) of the current window came since the stream (re)started.
    public private(set) var pictured = false
    /// The still on screen, nil while the video shows or nothing does.
    public private(set) var still: CGImage?

    public init() {}

    public mutating func apply(_ event: ComputerUsePreviewStream.Event) {
        switch event {
        case .status(let status):
            switch status.state {
            case .streaming, .still: blocked = false
            case .blocked: (blocked, pictured, still) = (true, false, nil)
            // The window is gone: nothing of it stays, and nothing shows until a window's picture.
            case .noWindow: (pictured, still) = (false, nil)
            case .paused: break
            }
        case .pictured: (pictured, still) = (true, nil)
        case .still(let image): (pictured, still) = (true, image)
        case .windowChanged, .closed: (pictured, still) = (false, nil)
        }
    }

    /// Whether the overlay stays hidden: its window is private, or (shown as a card or expanded) no
    /// picture of the current window has come yet. The chip a person hid the preview to shows without one.
    public func hidesOverlay(presentation: ComputerUsePreviewPresentation) -> Bool {
        blocked || (!pictured && presentation != .hidden)
    }
}
