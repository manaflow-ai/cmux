struct ArrowlessPopoverRootViewUpdatePolicy {
    enum Strategy {
        case none
        case immediate
        case deferredVisible
    }

    static func rootViewUpdateStrategy(isPresented: Bool, popoverIsShown: Bool) -> Strategy {
        if popoverIsShown { return .deferredVisible }
        if isPresented { return .immediate }
        return .none
    }
}
