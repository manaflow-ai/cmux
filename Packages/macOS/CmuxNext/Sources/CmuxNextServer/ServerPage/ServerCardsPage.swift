public import CmuxNextPages

extension PageDescriptor {
    /// The server cards (webviews/src/pages/server-cards): cmux-page://cmux.server-cards/, the menu bar item's
    /// popover routes and the floating ``WebCardPanel``'s cards (Add Server, Add Machine). A new card adds its ops'
    /// prefix here. Pair Another Machine and app health are native cards (``PairInviteDialog``).
    public static let serverCards = PageDescriptor(id: "cmux.server-cards", resource: "server-cards",
                                                   namespaces: ["cmux.card.", "cmux.addMachine.", "cmux.server."])
}
