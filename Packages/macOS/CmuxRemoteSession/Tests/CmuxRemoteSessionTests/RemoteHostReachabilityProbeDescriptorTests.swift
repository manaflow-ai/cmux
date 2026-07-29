import Darwin
import Foundation
import Testing

@testable import CmuxRemoteSession

extension RemoteSubprocessTests {
    @Suite("RemoteHostReachabilityProbe descriptor lifecycle")
    struct RemoteHostReachabilityProbeDescriptorTests {
        @Test("Repeated SSH config resolution closes every subprocess pipe")
        func repeatedResolutionClosesPipes() throws {
            let baseline = openPipeDescriptors()

            for _ in 0..<20 {
                let endpoint = RemoteHostReachabilityProbe.resolveEndpoint(
                    destination: "nobody@127.0.0.1",
                    port: 2222,
                    identityFile: nil,
                    sshOptions: [],
                    sshConfigFile: "/dev/null"
                )
                let resolved = try #require(endpoint)
                #expect(resolved.host == "127.0.0.1")
                #expect(resolved.port == 2222)
            }

            let leaked = openPipeDescriptors().subtracting(baseline)
            #expect(
                leaked.isEmpty,
                "SSH config resolution retained pipe descriptors after its children exited: \(leaked.sorted())"
            )
        }

        private func openPipeDescriptors() -> Set<Int32> {
            var descriptors: Set<Int32> = []
            for descriptor in 0..<getdtablesize() {
                var metadata = stat()
                guard fstat(descriptor, &metadata) == 0,
                      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO) else {
                    continue
                }
                descriptors.insert(descriptor)
            }
            return descriptors
        }
    }
}
