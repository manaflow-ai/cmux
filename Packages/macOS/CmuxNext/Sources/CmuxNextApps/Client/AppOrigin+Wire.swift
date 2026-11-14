public import CmuxNextDaemon

public nonisolated extension AppOrigin {
    /// The `apps-run` origin: `user` only for a user origin on a connection
    /// the daemon verified as the cmux app (`client-hello`
    /// `user_origin_allowed`, P8), as the Cloud app ops (`CloudAppLinks.ops`) do;
    /// `script` for everything else.
    func wire(userOriginAllowed: Bool) -> AppsRunRequest.Origin {
        self == .user && userOriginAllowed ? .user : .script
    }
}
