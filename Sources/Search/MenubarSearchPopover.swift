import AppKit
import SwiftUI

/// Hosts the global search palette in the menubar.
///
/// Anchored to the existing `NSStatusItem` in `AppDelegate`. Opens via
/// hotkey (default `⌥⌘F`, see `GlobalSearchHotkey`) or click.
///
/// Wiring step (P1): in `AppDelegate.applicationDidFinishLaunching`,
/// after `statusItem` is created, instantiate
/// `MenubarSearchPopover.shared.attach(to: statusItem.button)` and
/// register the hotkey.
@MainActor
public final class MenubarSearchPopover {
    public static let shared = MenubarSearchPopover()

    private let popover = NSPopover()
    private weak var anchor: NSView?

    private init() {
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 640, height: 420)
    }

    public func attach(to view: NSView?, index: SearchIndex) {
        anchor = view
        popover.contentViewController = NSHostingController(
            rootView: SearchPaletteView(index: index, onPick: { [weak self] hit in
                self?.dismiss()
                NotificationCenter.default.post(
                    name: .cmuxJumpToSearchHit, object: hit)
            }))
    }

    public func toggle() {
        if popover.isShown { dismiss() } else { show() }
    }

    public func show() {
        guard let anchor, popover.contentViewController != nil else { return }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    public func dismiss() { popover.performClose(nil) }
}

public extension Notification.Name {
    static let cmuxJumpToSearchHit = Notification.Name("cmux.jumpToSearchHit")
    static let cmuxFocusTitlebarSearch = Notification.Name("cmux.focusTitlebarSearch")
}

/// SwiftUI palette body.
struct SearchPaletteView: View {
    let index: SearchIndex
    let onPick: (SearchIndex.Hit) -> Void

    @State private var query: String = ""
    @State private var hits: [SearchIndex.Hit] = []
    @State private var selection: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search all windows, panels, browser tabs…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .padding(12)
                .onChange(of: query) { _, new in
                    Task { await refresh(new) }
                }
            Divider()
            List(Array(hits.enumerated()), id: \.offset, selection: $selection) { idx, hit in
                HitRow(hit: hit, hotkey: idx < 9 ? "⌘\(idx + 1)" : nil)
                    .onTapGesture { onPick(hit) }
            }
            .listStyle(.plain)
        }
        .frame(width: 640, height: 420)
    }

    private func refresh(_ q: String) async {
        guard !q.isEmpty else { hits = []; return }
        let result = await index.search(q)
        await MainActor.run { hits = result; selection = 0 }
    }
}

private struct HitRow: View {
    let hit: SearchIndex.Hit
    let hotkey: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(hit.kind.rawValue.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.secondary.opacity(0.15), in: Capsule())
            Text(hit.snippet).lineLimit(1)
            Spacer()
            if let hotkey {
                Text(hotkey).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
