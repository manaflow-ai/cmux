import CmuxNextSettings

/// Where a page's script FIFO (``PageScriptPipeline``) runs its scripts: the bridge of the engine
/// that shows the page now. ``PageWebView`` sets it to WebKit's or Chromium's (and to WebKit's on a
/// fallback); the pipeline is made before the view, so it holds this box, not the view.
@MainActor
final class PageScriptTarget {
    /// Nil while no engine shows a document: a Chromium page on its way has none, and it gets its
    /// theme and scale when it attaches (``PageWebView/startChromium(hosting:)``).
    var bridge: (any PageHostBridge)?
    /// False while the page waits for its first show (PageWebView+FirstShow.swift): it has no
    /// document, and a script would make WebKit launch its WebContent process
    /// (`WebPageProxy::runJavaScriptInFrameInScriptWorld` calls `launchInitialProcessIfNecessary`).
    /// Its scripts are dropped: no page code subscribes before a document runs, and the first
    /// document gets its theme and scale from its document-start scripts and `documentFinished()`.
    var hasDocument: Bool
    #if DEBUG || CMUX_BENCH_HOOKS
    /// Runs of envelopes the page got as data (the page push channel) and as scripts (`debug.page` `deliveries`).
    private(set) var dataDeliveries = 0
    private(set) var scriptDeliveries = 0
    #endif

    init(_ bridge: (any PageHostBridge)? = nil, hasDocument: Bool = true) {
        self.bridge = bridge
        self.hasDocument = hasDocument
    }

    /// The form the next run of envelopes takes: data while the bridge pushes envelopes, a script otherwise.
    var deliveryForm: PageDeliveryForm { pusher != nil ? .data : .script }

    private var pusher: (any PageHostPushing)? {
        guard let pusher = bridge as? any PageHostPushing, pusher.pushesEnvelopes else { return nil }
        return pusher
    }

    func evaluate(_ script: String) {
        guard hasDocument else { return }
        bridge?.evaluate(script)
    }

    /// Hands one run of envelopes to the page in the form it was rendered in. A run rendered as data for a
    /// bridge that no longer pushes (the page fell back to WebKit meanwhile) goes as its script.
    func deliver(_ delivery: PageDelivery) {
        guard hasDocument else { return }
        switch delivery {
        case .script(let script):
            noteDelivery(data: false)
            bridge?.evaluate(script)
        case .data(let json):
            if let pusher {
                noteDelivery(data: true)
                pusher.push(envelopes: json)
            } else {
                noteDelivery(data: false)
                bridge?.evaluate(PageRouter.receiveManyScript(data: json))
            }
        }
    }

    private func noteDelivery(data: Bool) {
        #if DEBUG || CMUX_BENCH_HOOKS
        if data { dataDeliveries += 1 } else { scriptDeliveries += 1 }
        #endif
    }
}

/// How a page gets a run of its router's envelopes: a `receiveMany` script, or (the page push channel,
/// ``PageHostPushing``) their JSON array as data.
nonisolated enum PageDeliveryForm: Sendable, Equatable {
    case script
    case data
}

/// One run of envelopes, rendered in a ``PageDeliveryForm``.
nonisolated enum PageDelivery: Sendable, Equatable {
    /// ``PageRouter/receiveManyScript(_:)``.
    case script(String)
    /// ``PageRouter/receiveManyData(_:)``.
    case data(String)

    /// `envelopes` in `form`.
    static func render(_ envelopes: [JSONValue], as form: PageDeliveryForm) -> PageDelivery {
        switch form {
        case .script: .script(PageRouter.receiveManyScript(envelopes))
        case .data: .data(PageRouter.receiveManyData(envelopes))
        }
    }
}
