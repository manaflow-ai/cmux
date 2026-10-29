public import AppKit
public import SwiftUI

// The SwiftUI side of the gated hosting view (VisibilityGatedHostingView.swift, HostingBodyCounter.swift):
// the content init, the root that counts each body evaluation, and the environment key views below read.
// The gate itself is AppKit; this is the hosting glue for the SwiftUI pages it gates.

extension VisibilityGatedHostingView {
    /// Hosts `content`, built in the root's body: the observable state it reads is the root's, and each
    /// evaluation counts (``bodyEvaluations``, `debug.observations`). Views below count themselves with
    /// `@Environment(\.hostingBodyCounter)`.
    public convenience init<Content: View>(owner: String, policy: Policy = .gated,
                                           @ViewBuilder content: @escaping @MainActor () -> Content) {
        let counter = HostingBodyCounter()
        self.init(owner: owner, policy: policy, counter: counter,
                  hosting: NSHostingView(rootView: HostingBodyCountedRoot(counter: counter, content: content)))
    }
}

extension EnvironmentValues {
    /// The counter of the gated hosting view a view is in (``VisibilityGatedHostingView``); nil elsewhere.
    @Entry public var hostingBodyCounter: HostingBodyCounter?
}

/// The root of a gated hosting view: builds the page's content in its body and counts each evaluation.
struct HostingBodyCountedRoot<Content: View>: View {
    let counter: HostingBodyCounter
    let content: @MainActor () -> Content

    var body: some View {
        counter.record()
        return content().environment(\.hostingBodyCounter, counter)
    }
}
