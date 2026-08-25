import Darwin
import Foundation

/// Revalidates a snapshot immediately before it receives plugin capabilities.
///
/// Filesystem flags are defense in depth, not the authorization boundary:
/// the owning user can clear `UF_IMMUTABLE`. This verifier checks descriptor
/// identity and the complete artifact fingerprint so a cleared flag or an
/// in-place rewrite fails closed before the launch gate is released.
struct CmuxPluginExecutionSnapshotVerifier {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Returns whether the snapshot still represents its approved bytes.
    func verify(_ snapshot: CmuxPluginExecutionSnapshot) -> Bool {
        guard snapshot.entrypointFileDescriptor >= 0,
              sameFile(snapshot.entrypointFileDescriptor, snapshot.entrypointURL),
              snapshot.pinnedFileDescriptors.allSatisfy({ relativePath, descriptor in
                  sameFile(
                      descriptor,
                      snapshot.directoryURL.appendingPathComponent(
                          relativePath,
                          isDirectory: false
                      )
                  )
              }),
              let manifestData = try? Data(contentsOf: snapshot.manifestURL),
              let manifest = try? JSONDecoder().decode(
                  CmuxExtensionManifest.self,
                  from: manifestData
              ),
              let entrypointDeclaration = manifest.entrypoint else {
            return false
        }

        let interpreterData: Data?
        if let interpreterDescriptor = snapshot.interpreterFileDescriptor {
            let interpreterURL = snapshot.directoryURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    ".cmux-interpreter/executable",
                    isDirectory: false
                )
            guard sameFile(interpreterDescriptor, interpreterURL),
                  let data = try? Data(contentsOf: interpreterURL) else {
                return false
            }
            interpreterData = data
        } else {
            interpreterData = nil
        }

        let fingerprint = try? CmuxPluginArtifactFingerprinter(
            fileManager: fileManager
        ).fingerprint(
            manifestData: manifestData,
            pluginDirectoryURL: snapshot.directoryURL,
            entrypointDeclaration: entrypointDeclaration,
            interpreterData: interpreterData
        )
        return fingerprint == snapshot.fingerprint
    }

    private func sameFile(_ descriptor: Int32, _ url: URL) -> Bool {
        var descriptorMetadata = Darwin.stat()
        var pathMetadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &descriptorMetadata) == 0,
              url.path.withCString({ Darwin.stat($0, &pathMetadata) }) == 0,
              (descriptorMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (pathMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            return false
        }
        return descriptorMetadata.st_dev == pathMetadata.st_dev
            && descriptorMetadata.st_ino == pathMetadata.st_ino
    }
}
