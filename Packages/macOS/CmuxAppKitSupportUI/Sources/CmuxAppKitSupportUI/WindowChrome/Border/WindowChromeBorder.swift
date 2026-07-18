public import AppKit
public import SwiftUI

/// One-pixel border derived from the terminal chrome background.
public struct WindowChromeBorder: View {
    private let orientation: WindowChromeBorderOrientation
    private let ignoresSafeAreaValue: Bool
    private let backgroundColorProvider: @MainActor () -> NSColor
    private let refreshNotificationName: Notification.Name?
    @State private var separatorColor: NSColor

    /// Creates a chrome border with an injected background color provider.
    public init(
        orientation: WindowChromeBorderOrientation,
        ignoresSafeArea: Bool = true,
        refreshNotificationName: Notification.Name? = nil,
        backgroundColorProvider: @escaping @MainActor () -> NSColor
    ) {
        self.orientation = orientation
        self.ignoresSafeAreaValue = ignoresSafeArea
        self.refreshNotificationName = refreshNotificationName
        self.backgroundColorProvider = backgroundColorProvider
        _separatorColor = State(
            initialValue: WindowChromeColorResolver().separatorColor(forChromeBackground: backgroundColorProvider())
        )
    }

    /// Rendered border body.
    public var body: some View {
        if ignoresSafeAreaValue {
            border.ignoresSafeArea()
        } else {
            border
        }
    }

    @ViewBuilder
    private var border: some View {
        let base = borderShape
            .onAppear {
                refreshSeparatorColor()
            }

        if let refreshNotificationName {
            base.onReceive(NotificationCenter.default.publisher(for: refreshNotificationName)) { _ in
                refreshSeparatorColor()
            }
        } else {
            base
        }
    }

    private var borderShape: some View {
        Rectangle()
            .fill(Color(nsColor: separatorColor))
            .frame(
                maxWidth: orientation == .horizontal ? .infinity : nil,
                maxHeight: orientation == .vertical ? .infinity : nil
            )
            .frame(
                width: orientation == .vertical ? 1 : nil,
                height: orientation == .horizontal ? 1 : nil
            )
    }

    private func refreshSeparatorColor() {
        separatorColor = WindowChromeColorResolver()
            .separatorColor(forChromeBackground: backgroundColorProvider())
    }
}
