#if os(iOS)
public import UIKit

extension TranscriptListViewController {
    func configureScrollEdgeEffects(for collection: UICollectionView) {
        if #available(iOS 26.0, *) {
            collection.topEdgeEffect.style = .soft
            collection.bottomEdgeEffect.style = .soft
            collection.topEdgeEffect.isHidden = false
            collection.bottomEdgeEffect.isHidden = false
        }
    }

    /// Registers the real floating chrome containers that shape the physical bottom fade.
    /// - Parameter containers: Composer and accessory-bar containers overlaying the transcript.
    public func setBottomEdgeElementContainers(_ containers: [UIView]) {
        let uniqueContainers = containers.reduce(into: [UIView]()) { result, container in
            guard !result.contains(where: { $0 === container }) else { return }
            result.append(container)
        }
        guard uniqueContainers.map(ObjectIdentifier.init)
            != bottomEdgeElementContainers.map(ObjectIdentifier.init)
        else {
            return
        }
        for interaction in bottomEdgeInteractions {
            interaction.view?.removeInteraction(interaction)
        }
        bottomEdgeElementContainers = uniqueContainers
        bottomEdgeInteractions.removeAll(keepingCapacity: true)
        guard #available(iOS 26.0, *) else { return }
        for container in uniqueContainers {
            let interaction = UIScrollEdgeElementContainerInteraction()
            interaction.scrollView = collectionView
            interaction.edge = .bottom
            container.addInteraction(interaction)
            bottomEdgeInteractions.append(interaction)
        }
    }

    /// Removes native edge-container registrations before the live transcript unmounts.
    public func prepareForDismantle() {
        removeScrollEdgeInteractions()
        bottomEdgeElementContainers.removeAll()
        topEdgeElementContainer = nil
    }

    func removeScrollEdgeInteractions() {
        for interaction in bottomEdgeInteractions {
            interaction.view?.removeInteraction(interaction)
        }
        bottomEdgeInteractions.removeAll()
        if let topEdgeInteraction {
            topEdgeInteraction.view?.removeInteraction(topEdgeInteraction)
        }
        topEdgeInteraction = nil
    }

    func reconcileTopEdgeElementContainer() {
        guard #available(iOS 26.0, *),
              let navigationBar = navigationController?.navigationBar
        else {
            return
        }
        guard topEdgeElementContainer !== navigationBar else { return }
        if let topEdgeInteraction {
            topEdgeInteraction.view?.removeInteraction(topEdgeInteraction)
        }
        let interaction = UIScrollEdgeElementContainerInteraction()
        interaction.scrollView = collectionView
        interaction.edge = .top
        navigationBar.addInteraction(interaction)
        topEdgeElementContainer = navigationBar
        topEdgeInteraction = interaction
    }
}
#endif
