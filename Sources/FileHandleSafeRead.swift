import Foundation

extension FileHandle {
    private static let cmuxDefaultReadChunkSize = 64 * 1024

    func cmuxReadAvailableData(maxLength: Int = FileHandle.cmuxDefaultReadChunkSize) -> Result<Data, Error> {
        do {
            let data = try read(upToCount: max(1, maxLength)) ?? Data()
            return .success(data)
        } catch {
            return .failure(error)
        }
    }

    func cmuxReadToEnd(maxChunkLength: Int = FileHandle.cmuxDefaultReadChunkSize) -> Result<Data, Error> {
        var data = Data()
        do {
            while true {
                guard let chunk = try read(upToCount: max(1, maxChunkLength)), !chunk.isEmpty else {
                    return .success(data)
                }
                data.append(chunk)
            }
        } catch {
            return .failure(error)
        }
    }
}
