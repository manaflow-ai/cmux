public import CmuxNextPages

extension PageDescriptor {
    /// The server page (webviews/src/pages/server-cards): cmux-page://cmux.server-cards/, the menu bar item's popover
    /// routes (the panel, Health, the pairing code). Every card (Add Server, Add Machine, Pair Another Machine, app
    /// health) is a native dialog card.
    public static let serverCards = PageDescriptor(id: "cmux.server-cards", resource: "server-cards", namespaces: ["cmux.card.", "cmux.server."])
}
