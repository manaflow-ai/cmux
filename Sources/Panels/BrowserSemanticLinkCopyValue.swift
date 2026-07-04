import Foundation

struct BrowserSemanticLinkCopyValue: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case emailAddress
        case phoneNumber
    }

    let kind: Kind
    let string: String

    init?(linkURL url: URL) {
        _ = url
        return nil
    }

    var menuTitle: String {
        switch kind {
        case .emailAddress:
            return String(localized: "browser.contextMenu.copyEmailAddress", defaultValue: "Copy Email Address")
        case .phoneNumber:
            return String(localized: "browser.contextMenu.copyPhoneNumber", defaultValue: "Copy Phone Number")
        }
    }

    private static func mailtoAddressList(from url: URL) -> String? {
        guard let decodedPath = decodedPath(from: url) else { return nil }
        let addresses = decodedPath.split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !addresses.isEmpty,
              addresses.allSatisfy({ !$0.isEmpty && $0.contains("@") }) else {
            return nil
        }
        return addresses.joined(separator: ",")
    }

    private static func telephoneNumber(from url: URL) -> String? {
        guard let decodedPath = decodedPath(from: url),
              decodedPath.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil
                || decodedPath.contains("+")
                || decodedPath.contains("*")
                || decodedPath.contains("#") else {
            return nil
        }
        return decodedPath
    }

    private static func decodedPath(from url: URL) -> String? {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .path
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return nil
        }
        return value
    }
}
