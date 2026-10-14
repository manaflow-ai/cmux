import AppKit
import CmuxSettings
import CmuxStatusBar
import CmuxStatusBarUI
import Foundation
import SwiftUI

struct BottomStatusBar: View {
    /// Runs the `actions` entry a `cmux-action:<id>` link names; false when there is none.
    let runAction: @MainActor (String) -> Bool

    private static let settings = StatusBarCatalogSection()

    /// Owned by AppDelegate and shared by every window, so the command runs once.
    @Environment(StatusBarFeed.self) private var feed: StatusBarFeed?
    @AppStorage(BottomStatusBar.settings.command.userDefaultsKey) private var command = ""
    @AppStorage(BottomStatusBar.settings.fontSize.userDefaultsKey) private var fontSize = 11.0
    @AppStorage(BottomStatusBar.settings.alignment.userDefaultsKey)
    private var alignment = SessionContentAlignment.left.rawValue

    var body: some View {
        Group {
            if let feed, feed.content != .hidden {
                bar(feed)
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .onAppear { feed?.run(command) }
        .onChange(of: command) { _, newCommand in feed?.run(newCommand) }
    }

    private func bar(_ feed: StatusBarFeed) -> some View {
        let size = CGFloat(min(max(fontSize, StatusBarCatalogSection.fontSizeRange.lowerBound), StatusBarCatalogSection.fontSizeRange.upperBound))
        return StatusBarLine(segments: Self.segments(feed.content), fontSize: size, alignment: frameAlignment, openLink: open)
            .frame(height: size + 11)
            .clipped()
            .background(Color(nsColor: GhosttyApp.shared.defaultBackgroundColor))
            .overlay(alignment: .top) {
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            }
            .contentShape(Rectangle())
            .onTapGesture { feed.requestRefresh() }
            .help(String(localized: "statusBar.help.refresh", defaultValue: "Click to refresh"))
    }

    private var frameAlignment: Alignment {
        switch SessionContentAlignment(rawValue: alignment) ?? .left {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private static func segments(_ content: StatusBarFeed.Content) -> [StatusBarSegment] {
        switch content {
        case .hidden:
            return []
        case .line(let segments):
            return segments
        case .silentExit:
            let message = String(localized: "statusBar.error.noOutput", defaultValue: "Status bar command exited without printing a line")
            return [StatusBarSegment(link: nil, runs: [StatusBarRun(text: message, color: .palette(1))])]
        }
    }

    private func open(_ link: String) {
        let actionScheme = "cmux-action:"
        if link.hasPrefix(actionScheme) {
            let id = String(link.dropFirst(actionScheme.count))
            if runAction(id.removingPercentEncoding ?? id) { return }
        } else if let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) {
            NSWorkspace.shared.open(url)
            return
        }
        NSSound.beep()
    }
}
