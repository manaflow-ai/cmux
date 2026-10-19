import CmuxSidebar
import CmuxSidebarProviderKit
import SwiftUI

extension VerticalTabsSidebar {
    func collapsedExtensionSidebarSectionIDs(for model: CmuxSidebarProviderRenderModel) -> Set<String> {
        Set(model.sections.filter { section in
            extensionSidebarDisclosure?.isCollapsed(providerID: model.providerId, sectionID: section.id)
                ?? localCollapsedExtensionSidebarSections.contains([model.providerId, section.id])
        }.map(\.id))
    }

    func setExtensionSidebarSectionCollapsed(_ collapsed: Bool, providerID: String, sectionID: String) {
        if let extensionSidebarDisclosure {
            extensionSidebarDisclosure.setCollapsed(collapsed, providerID: providerID, sectionID: sectionID)
        } else if collapsed {
            localCollapsedExtensionSidebarSections.insert([providerID, sectionID])
        } else {
            localCollapsedExtensionSidebarSections.remove([providerID, sectionID])
        }
    }
}
