struct ArrowlessPopoverRootViewUpdatePolicy {
    static func shouldUpdateRootView(isPresented: Bool, popoverIsShown: Bool) -> Bool {
        isPresented || popoverIsShown
    }
}
