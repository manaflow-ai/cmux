/// The relay link the supervisor gives each Chromium Host it starts: the app sets it when its provider
/// connection is accepted (and nil when it stops), and every host start of the session observes it, so a
/// host started before or after the link is known gets it at its attach.
public final class ChromiumHostAgentRelay {
    public private(set) var link: ChromiumHostRelayLink?
    private var observers: [(ChromiumHostRelayLink?) -> Void] = []

    public init() {}

    public func setRelayLink(_ link: ChromiumHostRelayLink?) {
        guard link != self.link else { return }
        self.link = link
        for observer in observers { observer(link) }
    }

    /// Calls `changed` with the current link now and with each change after.
    func observe(_ changed: @escaping (ChromiumHostRelayLink?) -> Void) {
        observers.append(changed)
        changed(link)
    }
}

/// A ``ChromiumHostSupervising`` whose hosts take the browser host's relay link: the
/// host start observes ``agentRelay``. A supervisor without it relays every agent tab through cmux.
public protocol ChromiumHostAgentRelaying: ChromiumHostSupervising {
    var agentRelay: ChromiumHostAgentRelay { get }
}
