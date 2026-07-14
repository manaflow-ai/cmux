enum GhosttyPresentationSuppression {
    static func shouldHideRenderer(
        isRenderDispatchSuppressed: Bool,
        isAuthoritativeGridPresented: Bool
    ) -> Bool {
        isRenderDispatchSuppressed || isAuthoritativeGridPresented
    }
}
