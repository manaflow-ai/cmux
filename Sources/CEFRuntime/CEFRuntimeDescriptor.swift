import Foundation

struct CEFRuntimeDescriptor: Equatable, Sendable {
    let version: String
    let tarballName: String
    let tarballSHA1: String
    let tarballSHA256: String
    let tarballSizeBytes: Int64
    let extractedDirectoryName: String
    let sourceBaseURL: URL

    static var current: CEFRuntimeDescriptor {
        bundledLockfileDescriptor() ?? fallbackCurrent
    }

    private static let fallbackCurrent = CEFRuntimeDescriptor(
        version: "146.0.10+g8219561+chromium-146.0.7680.179",
        tarballName: "cef_binary_146.0.10+g8219561+chromium-146.0.7680.179_macosarm64.tar.bz2",
        tarballSHA1: "a483c800e506a592c63b60b36a12127eea3fc39f",
        tarballSHA256: "01d134dd8f0ac37b231b0fefbe272d77dc932e4754d53c5f576dec70dd0b035f",
        tarballSizeBytes: 282_101_327,
        extractedDirectoryName: "cef_binary_146.0.10+g8219561+chromium-146.0.7680.179_macosarm64",
        sourceBaseURL: URL(string: "https://cef-builds.spotifycdn.com/")!
    )

    private static func bundledLockfileDescriptor(bundle: Bundle = .main) -> CEFRuntimeDescriptor? {
        guard let url = bundle.url(forResource: "cef.lock", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let lock = try? JSONDecoder().decode(CEFLockfile.self, from: data),
              let platform = lock.platforms["macosarm64"],
              let source = lock.sources.first,
              let baseURL = URL(string: source.baseURL) else {
            return nil
        }
        return CEFRuntimeDescriptor(
            version: lock.version,
            tarballName: platform.tarball,
            tarballSHA1: platform.sha1,
            tarballSHA256: platform.sha256,
            tarballSizeBytes: platform.sizeBytes,
            extractedDirectoryName: platform.extractedDirectoryName,
            sourceBaseURL: baseURL
        )
    }

    var downloadURL: URL {
        var baseComponents = URLComponents(url: sourceBaseURL, resolvingAgainstBaseURL: false)
        let basePath = baseComponents?.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        var filenameAllowedCharacters = CharacterSet.urlPathAllowed
        filenameAllowedCharacters.remove(charactersIn: "+")
        let encodedName = tarballName.addingPercentEncoding(withAllowedCharacters: filenameAllowedCharacters) ?? tarballName
        baseComponents?.percentEncodedPath = "/" + [basePath, encodedName]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        return baseComponents?.url ?? sourceBaseURL.appendingPathComponent(tarballName)
    }

    static let requiredFreeBytes: Int64 = 2_500_000_000
}

private struct CEFLockfile: Decodable {
    struct Platform: Decodable {
        let tarball: String
        let sha1: String
        let sha256: String
        let sizeBytes: Int64
        let extractedDirectoryName: String

        private enum CodingKeys: String, CodingKey {
            case tarball
            case sha1
            case sha256
            case sizeBytes = "size_bytes"
            case extractedDirectoryName = "extracted_dir_name"
        }
    }

    struct Source: Decodable {
        let baseURL: String

        private enum CodingKeys: String, CodingKey {
            case baseURL = "base_url"
        }
    }

    let version: String
    let platforms: [String: Platform]
    let sources: [Source]
}
