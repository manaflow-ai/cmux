public import AppKit

/// What a window's ``FrameScheduler`` holds of its window's occlusion (FrameScheduler+Occlusion.swift).
struct OcclusionHold {
    /// Its window's family says occluded.
    var isOccluded = false
    /// Active clients that wait off the link until the window can be seen again.
    var held: [ObjectIdentifier: FrameClient] = [:]
    /// Its subscription to the window's family.
    var subscription: WindowOcclusionSubscription?
    /// Times a flip to visible put held clients back on the link.
    var restores = 0
}

/// Occluded windows make no frames (rendering-DESIGN R6).
///
/// A window scheduler follows its window's ``WindowOcclusionFamily`` (``forWindow(_:)``), which flips
/// only while its source runs (feature `windowOcclusionFamily`). While the window is occluded its animation
/// clients leave the link and wait, so a window that only animates holds no display subscription and
/// gets no ticks; the window shown again puts them back in one step, ticking from the next frame. Its
/// input stage and its batch clients (``FrameClient/isAnimation`` false: a drain, a settle wait)
/// keep ticking, at the stall rate the display gives a window nobody sees: work someone waits for
/// goes on. Chrome stops BeginFrames to an occluded widget the same way
/// (`RenderWidgetHostViewMac::WasOccluded`, content/browser/renderer_host/render_widget_host_view_mac.mm).
extension FrameScheduler {
    /// Its window is occluded: its animation clients wait off the link.
    public var isWindowOccluded: Bool { occlusionHold.isOccluded }

    /// Owners of the active clients that wait for the window to be seen.
    public var occludedClients: [String] {
        occlusionHold.held.values.map(\.owner).sorted()
    }

    /// Times the window shown again put waiting clients back on the link.
    public var occlusionRestores: Int { occlusionHold.restores }

    /// Whether someone may see the frames it makes: a window-less scheduler always; a window one while
    /// its family does not say occluded and `isVisible` (its ``DisplayClock``'s resolver) says so.
    func isSeen(by isVisible: DisplayClock.VisibilityResolver) -> Bool {
        guard let window = hostWindow else { return true }
        return !occlusionHold.isOccluded && isVisible(window)
    }

    /// Follows `family` from now on (a window scheduler, made with its window's family).
    func follow(_ family: WindowOcclusionFamily) {
        occlusionHold.subscription = family.subscribe(.content, owner: "FrameScheduler \(name)") { [weak self] occluded in
            self?.occlusionDidChange(occluded)
        }
        occlusionDidChange(family.isOccluded)
    }

    /// Whether `client`, activating, waits for its window to be seen: an animation client while the
    /// window is occluded is held in ``OcclusionHold/held``, off the link.
    func waitsForVisibleWindow(_ client: FrameClient) -> Bool {
        guard occlusionHold.isOccluded, Self.pausesWhenOccluded(client) else { return false }
        occlusionHold.held[ObjectIdentifier(client)] = client
        return true
    }

    /// Its window closed: its waiting clients go idle without calling back. It keeps following the
    /// family, which lives as long as the window: a window shown again keeps its scheduler.
    func detachOccluded() {
        for client in occlusionHold.held.values { client.detach() }
        occlusionHold.held.removeAll()
    }

    /// The window was occluded or seen again.
    func occlusionDidChange(_ occluded: Bool) {
        guard occluded != occlusionHold.isOccluded else { return }
        occlusionHold.isOccluded = occluded
        if occluded {
            for client in clients.values where Self.pausesWhenOccluded(client) {
                deactivate(client)
                occlusionHold.held[ObjectIdentifier(client)] = client
            }
        } else {
            let waiting = Array(occlusionHold.held.values)
            occlusionHold.held.removeAll()
            guard !waiting.isEmpty else { return }
            occlusionHold.restores += 1
            for client in waiting where client.isActive { activate(client) }
        }
    }

    /// An animation stops while nobody can see its window; input and batch work go on.
    private static func pausesWhenOccluded(_ client: FrameClient) -> Bool {
        client.isAnimation && client.workClass == .frame
    }
}
