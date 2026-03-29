> Cette traduction a été générée par Claude. Si vous avez des suggestions d'amélioration, ouvrez une PR.

<h1 align="center">cmux</h1>
<p align="center">Un terminal macOS basé sur Ghostty avec des onglets verticaux et des notifications pour les agents de programmation IA</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Télécharger cmux pour macOS" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | Français | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a> | <a href="README.uk.md">Українська</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="Capture d'écran de cmux" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ Vidéo de démonstration</a> · <a href="https://cmux.com/blog/zen-of-cmux">The Zen of cmux</a>
</p>

## Fonctionnalités

<table>
<tr>
<td width="40%" valign="middle">
<h3>Anneaux de notification</h3>
Les panneaux reçoivent un anneau bleu et les onglets s'illuminent lorsque les agents de programmation ont besoin de votre attention
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="Anneaux de notification" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Panneau de notifications</h3>
Consultez toutes les notifications en attente au même endroit, accédez directement à la plus récente non lue
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="Badge de notification dans la barre latérale" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Navigateur intégré</h3>
Divisez un navigateur à côté de votre terminal avec une API scriptable portée depuis <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="Navigateur intégré" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Onglets verticaux + horizontaux</h3>
La barre latérale affiche la branche git, le statut/numéro de PR lié, le répertoire de travail, les ports en écoute et le texte de la dernière notification. Divisez horizontalement et verticalement.
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="Onglets verticaux et panneaux divisés" width="100%" />
</td>
</tr>
</table>

- **Scriptable** — CLI et API socket pour créer des espaces de travail, diviser des panneaux, envoyer des frappes clavier et automatiser le navigateur
- **Application macOS native** — Construite avec Swift et AppKit, pas Electron. Démarrage rapide, faible consommation mémoire.
- **Compatible Ghostty** — Lit votre fichier `~/.config/ghostty/config` existant pour les thèmes, polices et couleurs
- **Accélération GPU** — Propulsé par libghostty pour un rendu fluide

## Installation

### DMG (recommandé)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="Télécharger cmux pour macOS" width="180" />
</a>

Ouvrez le `.dmg` et glissez cmux dans votre dossier Applications. cmux se met à jour automatiquement via Sparkle, vous n'avez donc besoin de le télécharger qu'une seule fois.

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

Pour mettre à jour plus tard :

```bash
brew upgrade --cask cmux
```

Au premier lancement, macOS peut vous demander de confirmer l'ouverture d'une application provenant d'un développeur identifié. Cliquez sur **Ouvrir** pour continuer.

## Pourquoi cmux ?

J'exécute beaucoup de sessions Claude Code et Codex en parallèle. J'utilisais Ghostty avec plein de panneaux divisés et je comptais sur les notifications natives de macOS pour savoir quand un agent avait besoin de moi. Mais le contenu des notifications de Claude Code est toujours juste « Claude is waiting for your input » sans aucun contexte, et avec suffisamment d'onglets ouverts, je ne pouvais même plus lire les titres.

J'ai essayé quelques orchestrateurs de programmation, mais la plupart étaient des applications Electron/Tauri et les performances me dérangeaient. Je préfère aussi simplement le terminal, car les orchestrateurs à interface graphique vous enferment dans leur flux de travail. J'ai donc construit cmux comme une application macOS native en Swift/AppKit. Elle utilise libghostty pour le rendu du terminal et lit votre configuration Ghostty existante pour les thèmes, polices et couleurs.

Les principaux ajouts sont la barre latérale et le système de notifications. La barre latérale comporte des onglets verticaux qui affichent la branche git, le statut/numéro de PR lié, le répertoire de travail, les ports en écoute et le texte de la dernière notification pour chaque espace de travail. Le système de notifications capte les séquences de terminal (OSC 9/99/777) et dispose d'un CLI (`cmux notify`) que vous pouvez brancher aux hooks d'agents pour Claude Code, OpenCode, etc. Quand un agent est en attente, son panneau reçoit un anneau bleu et l'onglet s'illumine dans la barre latérale, pour que je puisse identifier lequel a besoin de moi parmi les divisions et les onglets. ⌘⇧U permet de sauter à la notification non lue la plus récente.

Le navigateur intégré dispose d'une API scriptable portée depuis [agent-browser](https://github.com/vercel-labs/agent-browser). Les agents peuvent capturer l'arbre d'accessibilité, obtenir des références d'éléments, cliquer, remplir des formulaires et exécuter du JS. Vous pouvez diviser un panneau navigateur à côté de votre terminal et laisser Claude Code interagir directement avec votre serveur de développement.

Tout est scriptable via le CLI et l'API socket — créer des espaces de travail/onglets, diviser des panneaux, envoyer des frappes clavier, ouvrir des URL dans le navigateur.

## The Zen of cmux

cmux ne prescrit pas comment les développeurs utilisent leurs outils. C'est un terminal et un navigateur avec un CLI, le reste vous appartient.

cmux est une primitive, pas une solution. Il vous donne un terminal, un navigateur, des notifications, des espaces de travail, des divisions, des onglets et un CLI pour tout contrôler. cmux ne vous impose pas une façon préconçue d'utiliser les agents de programmation. Ce que vous construisez avec ces primitives vous appartient.

Les meilleurs développeurs ont toujours construit leurs propres outils. Personne n'a encore trouvé la meilleure façon de travailler avec les agents, et les équipes qui construisent des produits fermés ne l'ont pas trouvée non plus. Les développeurs les plus proches de leurs propres bases de code trouveront la solution en premier.

Donnez à un million de développeurs des primitives composables et ils trouveront collectivement les flux de travail les plus efficaces plus rapidement que n'importe quelle équipe produit ne pourrait les concevoir de manière descendante.

## Documentation

Pour plus d'informations sur la configuration de cmux, [consultez notre documentation](https://cmux.com/docs/getting-started?utm_source=readme).

## Raccourcis clavier

### Espaces de travail

| Raccourci | Action |
|----------|--------|
| ⌘ N | Nouvel espace de travail |
| ⌘ 1–8 | Aller à l'espace de travail 1–8 |
| ⌘ 9 | Aller au dernier espace de travail |
| ⌃ ⌘ ] | Espace de travail suivant |
| ⌃ ⌘ [ | Espace de travail précédent |
| ⌘ ⇧ W | Fermer l'espace de travail |
| ⌘ ⇧ R | Renommer l'espace de travail |
| ⌘ B | Basculer la barre latérale |

### Surfaces

| Raccourci | Action |
|----------|--------|
| ⌘ T | Nouvelle surface |
| ⌘ ⇧ ] | Surface suivante |
| ⌘ ⇧ [ | Surface précédente |
| ⌃ Tab | Surface suivante |
| ⌃ ⇧ Tab | Surface précédente |
| ⌃ 1–8 | Aller à la surface 1–8 |
| ⌃ 9 | Aller à la dernière surface |
| ⌘ W | Fermer la surface |

### Panneaux divisés

| Raccourci | Action |
|----------|--------|
| ⌘ D | Diviser à droite |
| ⌘ ⇧ D | Diviser vers le bas |
| ⌥ ⌘ ← → ↑ ↓ | Focaliser le panneau directionnellement |
| ⌘ ⇧ H | Faire clignoter le panneau focalisé |

### Navigateur

Les raccourcis des outils de développement du navigateur suivent les valeurs par défaut de Safari et sont personnalisables dans `Paramètres → Raccourcis clavier`.

| Raccourci | Action |
|----------|--------|
| ⌘ ⇧ L | Ouvrir le navigateur en division |
| ⌘ L | Focaliser la barre d'adresse |
| ⌘ [ | Reculer |
| ⌘ ] | Avancer |
| ⌘ R | Recharger la page |
| ⌥ ⌘ I | Basculer les outils de développement (par défaut Safari) |
| ⌥ ⌘ C | Afficher la console JavaScript (par défaut Safari) |

### Notifications

| Raccourci | Action |
|----------|--------|
| ⌘ I | Afficher le panneau de notifications |
| ⌘ ⇧ U | Aller à la dernière non lue |

### Recherche

| Raccourci | Action |
|----------|--------|
| ⌘ F | Rechercher |
| ⌘ G / ⌘ ⇧ G | Résultat suivant / précédent |
| ⌘ ⇧ F | Masquer la barre de recherche |
| ⌘ E | Utiliser la sélection pour la recherche |

### Terminal

| Raccourci | Action |
|----------|--------|
| ⌘ K | Effacer l'historique de défilement |
| ⌘ C | Copier (avec sélection) |
| ⌘ V | Coller |
| ⌘ + / ⌘ - | Augmenter / diminuer la taille de police |
| ⌘ 0 | Réinitialiser la taille de police |

### Fenêtre

| Raccourci | Action |
|----------|--------|
| ⌘ ⇧ N | Nouvelle fenêtre |
| ⌘ , | Paramètres |
| ⌘ ⇧ , | Recharger la configuration |
| ⌘ Q | Quitter |

## Builds Nightly

[Télécharger cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY est une application séparée avec son propre identifiant de bundle, elle fonctionne donc en parallèle de la version stable. Construite automatiquement à partir du dernier commit `main` et mise à jour automatiquement via son propre flux Sparkle.

## Restauration de session (comportement actuel)

Au relancement, cmux restaure actuellement uniquement la disposition et les métadonnées de l'application :
- Disposition des fenêtres/espaces de travail/panneaux
- Répertoires de travail
- Historique de défilement du terminal (au mieux)
- URL du navigateur et historique de navigation

cmux ne restaure **pas** l'état des processus actifs dans les applications du terminal. Par exemple, les sessions actives de Claude Code/tmux/vim ne sont pas encore reprises après un redémarrage.

## Historique des étoiles

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## Contribuer

Façons de s'impliquer :

- Suivez-nous sur X pour les mises à jour [@manaflowai](https://x.com/manaflowai), [@lawrencecchen](https://x.com/lawrencecchen), et [@austinywang](https://x.com/austinywang)
- Rejoignez la conversation sur [Discord](https://discord.gg/xsgFEVrWCZ)
- Créez et participez aux [issues GitHub](https://github.com/manaflow-ai/cmux/issues) et aux [discussions](https://github.com/manaflow-ai/cmux/discussions)
- Dites-nous ce que vous construisez avec cmux

## Communauté

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

## Édition Fondateur

cmux est gratuit, open source, et le restera toujours. Si vous souhaitez soutenir le développement et obtenir un accès anticipé à ce qui arrive :

**[Obtenir l'Édition Fondateur](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **Demandes de fonctionnalités et corrections de bugs prioritaires**
- **Accès anticipé : cmux AI qui vous donne du contexte sur chaque espace de travail, onglet et panneau**
- **Accès anticipé : application iOS avec des terminaux synchronisés entre ordinateur et téléphone**
- **Accès anticipé : VMs cloud**
- **Accès anticipé : Mode vocal**
- **Mon iMessage/WhatsApp personnel**

## Licence

cmux est open source sous [AGPL-3.0-or-later](LICENSE).

Si votre organisation ne peut pas se conformer à l'AGPL, une licence commerciale est disponible. Contactez [founders@manaflow.com](mailto:founders@manaflow.com) pour plus de détails.
