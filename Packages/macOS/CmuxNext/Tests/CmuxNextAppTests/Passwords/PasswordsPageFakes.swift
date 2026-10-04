import AppKit
@testable import CmuxNextApp
import CmuxNextBrowserImport
import CmuxNextPages
import Foundation

/// Native-layer stand-ins for the Passwords page tests: the confirmation sheet, device owner
/// authentication and the secret surface record what reached them.
@MainActor
final class PasswordSheetFake: PageConfirmationPresenter {
    var answer: Bool
    private(set) var shown: [PageConfirmation] = []
    var onShow: (() -> Void)?
    init(answer: Bool = true) { self.answer = answer }
    func confirm(_ confirmation: PageConfirmation, anchor: NSView?) async -> Bool {
        shown.append(confirmation)
        onShow?()
        return answer
    }
}

@MainActor
final class DeviceOwnerFake: DeviceOwnerAuthenticating {
    var answer: Bool
    private(set) var reasons: [String] = []
    var onAsk: (() -> Void)?
    init(answer: Bool = true) { self.answer = answer }
    func authenticate(reason: String) async -> Bool {
        reasons.append(reason)
        onAsk?()
        return answer
    }
}

@MainActor
final class SecretSurfaceFake: PasswordSecretSurface {
    private(set) var revealed: [(site: String, username: String, secret: String)] = []
    private(set) var copied: [String] = []
    var destination: URL?
    private(set) var destinationAsks = 0
    var onDestination: (() -> Void)?

    func reveal(_ secret: SecretBytes, site: String, username: String, anchor: NSView?) async {
        revealed.append((site, username, secret.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }))
    }

    func copy(_ secret: SecretBytes) {
        copied.append(secret.withUnsafeBytes { String(decoding: $0, as: UTF8.self) })
    }

    func exportDestination(profileName: String, anchor: NSView?) async -> URL? {
        destinationAsks += 1
        onDestination?()
        return destination
    }
}
