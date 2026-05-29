/// Public identifiers for the CMUX sidebar ExtensionKit surface.
public enum CMUXSidebarExtensionPoint {
    /// Extension point identifier third-party sidebar extensions register against.
    public static let identifier = "com.manaflow.cmux.sidebar"
    /// StaticString form required by the modern ExtensionFoundation monitor API.
    public static let staticIdentifier: StaticString = "com.manaflow.cmux.sidebar"
    /// Default ExtensionKit scene identifier hosted inside the cmux sidebar.
    public static let defaultSceneID = "sidebar"
}
