public import AppKit
public import SwiftUI

// The SwiftUI side of the gate's body counter (VisibilityGatedHostingView.swift, HostingBodyCounter.swift):
// a root that counts each body evaluation of a gated SwiftUI page, so debug.observations and the benches
// can show that a hidden page runs no body. It goes when the last gated page is AppKit.

extension VisibilityGatedHostingView {
    /// Hosts `content`, built in the root's body: the observable state it reads is the root's, and each
    /// evaluation counts (``bodyEvaluations``, `debug.observations`).
    public convenience init<Content: View>(owner: String, policy: Policy = .gated,
                                           @ViewBuilder content: @escaping @MainActor () -> Content) {
        let counter = HostingBodyCounter()
        self.init(owner: owner, policy: policy, counter: counter,
                  hosting: NSHostingView(rootView: HostingBodyCountedRoot(counter: counter, content: content)))
    }
}

/// The root of a gated hosting view: builds the page's content in its body and counts each evaluation.
struct HostingBodyCountedRoot<Content: View>: View {
    let counter: HostingBodyCounter
    let content: @MainActor () -> Content

    var body: some View {
        counter.record()
        return content()
    }
}
