public import AppKit
public import Observation
public import SwiftUI

/// Colors resolved by an AppKit host in its theme scope, observed by the
/// SwiftUI tree below it (hosting views call `update(from:)` when they move
/// to a window or the appearance changes).
@MainActor
@Observable
public final class AppSceneAppearance {
    public var colors: AppSceneColors = .fallback

    public init() {}

    public func update(from view: NSView) {
        let resolved = AppSceneColors.resolve(in: view)
        if resolved != colors { colors = resolved }
    }
}

/// Injects an `AppSceneAppearance`'s colors into the environment.
public struct AppSceneThemedRoot<Content: View>: View {
    let appearance: AppSceneAppearance
    let content: Content

    public init(appearance: AppSceneAppearance, @ViewBuilder content: () -> Content) {
        self.appearance = appearance
        self.content = content()
    }

    public var body: some View {
        content.environment(\.appSceneColors, appearance.colors)
    }
}
