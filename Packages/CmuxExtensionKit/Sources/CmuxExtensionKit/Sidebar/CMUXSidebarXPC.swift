import Foundation

@objc public protocol CMUXSidebarHostXPC: NSObjectProtocol {
    func requestSidebarSnapshot(reply: @escaping (NSData?, NSString?) -> Void)
    func performSidebarAction(_ payload: NSData, reply: @escaping (NSData?, NSString?) -> Void)
}

@objc public protocol CMUXSidebarExtensionXPC: NSObjectProtocol {
    @objc optional func requestExtensionManifest(reply: @escaping (NSData?, NSString?) -> Void)
    func sidebarSnapshotDidChange(_ payload: NSData)
}

public enum CMUXSidebarXPCCodec {
    public static func encodeSnapshot(_ snapshot: CMUXSidebarSnapshot) throws -> NSData {
        try JSONEncoder().encode(snapshot) as NSData
    }

    public static func decodeSnapshot(_ payload: NSData) throws -> CMUXSidebarSnapshot {
        try JSONDecoder().decode(CMUXSidebarSnapshot.self, from: payload as Data)
    }

    public static func encodeManifest(_ manifest: CMUXExtensionManifest) throws -> NSData {
        try JSONEncoder().encode(manifest) as NSData
    }

    public static func decodeManifest(_ payload: NSData) throws -> CMUXExtensionManifest {
        try JSONDecoder().decode(CMUXExtensionManifest.self, from: payload as Data)
    }

    public static func encodeAction(_ action: CMUXSidebarAction) throws -> NSData {
        try JSONEncoder().encode(action) as NSData
    }

    public static func decodeAction(_ payload: NSData) throws -> CMUXSidebarAction {
        try JSONDecoder().decode(CMUXSidebarAction.self, from: payload as Data)
    }

    public static func encodeActionResult(_ result: CMUXExtensionActionResult) throws -> NSData {
        try JSONEncoder().encode(result) as NSData
    }

    public static func decodeActionResult(_ payload: NSData) throws -> CMUXExtensionActionResult {
        try JSONDecoder().decode(CMUXExtensionActionResult.self, from: payload as Data)
    }
}
