import AppKit

@MainActor
protocol FileDropPaneTarget: AnyObject {
    func fileDropDraggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation
    func fileDropDraggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation
    func fileDropDraggingExited(_ sender: (any NSDraggingInfo)?)
    func fileDropPrepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool
    func fileDropPerformDragOperation(_ sender: any NSDraggingInfo) -> Bool
    func fileDropConcludeDragOperation(_ sender: (any NSDraggingInfo)?)
}

extension PaneDropTargetView: FileDropPaneTarget {
    func fileDropDraggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    func fileDropDraggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    func fileDropDraggingExited(_ sender: (any NSDraggingInfo)?) { draggingExited(sender) }
    func fileDropPrepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { prepareForDragOperation(sender) }
    func fileDropPerformDragOperation(_ sender: any NSDraggingInfo) -> Bool { performDragOperation(sender) }
    func fileDropConcludeDragOperation(_ sender: (any NSDraggingInfo)?) { concludeDragOperation(sender) }
}

extension BrowserPaneDropTargetView: FileDropPaneTarget {
    func fileDropDraggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    func fileDropDraggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    func fileDropDraggingExited(_ sender: (any NSDraggingInfo)?) { draggingExited(sender) }
    func fileDropPrepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { prepareForDragOperation(sender) }
    func fileDropPerformDragOperation(_ sender: any NSDraggingInfo) -> Bool { performDragOperation(sender) }
    func fileDropConcludeDragOperation(_ sender: (any NSDraggingInfo)?) { concludeDragOperation(sender) }
}
