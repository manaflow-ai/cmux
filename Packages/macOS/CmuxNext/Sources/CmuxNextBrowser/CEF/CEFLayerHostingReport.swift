import Foundation

/// Layer hosting (fork API 26) across the live Chromium host views
/// (`debug.cef` `layer_hosting`). A gauge worked out when read, not counters
/// since launch: a host view that went away (a pane closed, DevTools closed)
/// takes its numbers with it, so a bench reads it at a point in time and
/// compares counts only across a span in which no host view closed.
public nonisolated struct CEFLayerHostingReport: Equatable, Sendable {
    /// Live host views: pane hosts and docked DevTools.
    public var hostViews = 0
    /// Host views whose page draws in a cmux window's layer tree now (a
    /// hosted page view in a window).
    public var hostedPages = 0
    /// Requests the fork refused, or contexts no `CALayerHost` could show,
    /// of the live host views.
    public var refusals = 0
    /// Layer hosting calls into the fork made by the live host views (a tab
    /// switch inside a hosted pane makes none).
    public var forkCalls = 0

    public init() {}

    /// The sums over `hostings` (main actor: it reads their state).
    @MainActor init(hostings: [CEFLayerHosting]) {
        hostViews = hostings.count
        for hosting in hostings {
            if hosting.isHostedInWindow { hostedPages += 1 }
            refusals += hosting.refusals
            forkCalls += hosting.forkCalls
        }
    }
}
