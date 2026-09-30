import CoreGraphics
import Darwin

/// Owns a descriptor-backed ImageIO data provider for the lifetime of a decode.
final class ArtifactImageDataProvider {
    private final class Context {
        let fileDescriptor: Int32

        init(fileDescriptor: Int32) {
            self.fileDescriptor = fileDescriptor
        }

        deinit {
            _ = Darwin.close(fileDescriptor)
        }
    }

    let value: CGDataProvider

    init(fileDescriptor: Int32, size: Int64) throws {
        guard size >= 0 else {
            throw ArtifactByteReader.Error.readFailed
        }
        let duplicate = Darwin.fcntl(fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw ArtifactByteReader.Error.readFailed
        }
        let info = Unmanaged.passRetained(Context(fileDescriptor: duplicate)).toOpaque()
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0,
            getBytePointer: nil,
            releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, position, count in
                guard let info, position >= 0, count > 0 else { return 0 }
                let context = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()
                let result = Darwin.pread(context.fileDescriptor, buffer, count, position)
                return result > 0 ? result : 0
            },
            releaseInfo: { info in
                guard let info else { return }
                _ = Unmanaged<Context>.fromOpaque(info).takeRetainedValue()
            }
        )
        guard let provider = withUnsafePointer(to: &callbacks, {
            CGDataProvider(
                directInfo: info,
                size: off_t(size),
                callbacks: $0
            )
        }) else {
            Unmanaged<Context>.fromOpaque(info).release()
            throw ArtifactByteReader.Error.readFailed
        }
        self.value = provider
    }
}
