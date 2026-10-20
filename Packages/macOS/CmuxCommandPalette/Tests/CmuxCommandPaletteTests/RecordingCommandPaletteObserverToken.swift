import Foundation

final class RecordingCommandPaletteObserverToken: NSObject {
    let id: Int

    init(id: Int) {
        self.id = id
        super.init()
    }
}
