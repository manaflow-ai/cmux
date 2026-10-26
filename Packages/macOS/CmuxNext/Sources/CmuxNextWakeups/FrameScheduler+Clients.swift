extension FrameScheduler {
    /// Owners of the clients that are ticking now.
    public var activeClients: [String] {
        clients.values.filter(\.isActive).map(\.owner).sorted()
    }

    /// A frame-locked client (``MainWorkClass/frame``: a spring, an autoscroll, a drain) is ticking:
    /// a late tick of this scheduler is a late frame.
    public var hasActiveFrameClients: Bool {
        clients.values.contains { $0.isActive && $0.workClass == .frame }
    }
}
