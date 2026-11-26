import Foundation
import NetworkExtension

// A network system extension is a plain executable that the system launches
// and talks to over NetworkExtension's IPC. `startSystemExtensionMode` reads
// `NEProviderClasses` from Info.plist, instantiates `PacketTunnelProvider`
// when the system starts the tunnel, and keeps serving until the process is
// told to exit. `dispatchMain()` parks the main thread for that.
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
