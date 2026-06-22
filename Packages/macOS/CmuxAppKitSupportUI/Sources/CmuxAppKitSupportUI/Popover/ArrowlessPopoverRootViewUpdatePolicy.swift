struct ArrowlessPopoverRootViewUpdatePolicy {
    func shouldUpdateRootView(isPresented: Bool, popoverIsShown: Bool) -> Bool {
        isPresented || popoverIsShown
    }
}
