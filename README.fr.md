> Cette traduction a été générée par Claude. Si vous avez des suggestions d'amélioration, ouvrez une PR.

<h1 align="center">cmux</h1>
<p align="center">Un terminal macOS basé sur Ghostty avec des onglets verticaux et des notifications pour les agents de programmation IA</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Télécharger cmux pour macOS" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.vi.md">Tiếng Việt</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | Français | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a> | <a href="README.uk.md">Українська</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
  <a href="https://github.com/manaflow-ai/cmux"><img src="https://img.shields.io/github/stars/manaflow-ai/cmux?style=flat&logo=github&label=stars&color=4c71f2" alt="GitHub stars" /></a>
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
<tr>
<td width="40%" valign="middle">
<h3>SSH</h3>
<code>cmux ssh user@remote</code> crée un espace de travail pour une machine distante. Les panneaux navigateur sont routés via le réseau distant, donc localhost fonctionne directement. Glissez une image dans une session distante pour la transférer via scp.
</td>
<td width="60%">
<img src="./docs/assets/ssh.png" alt="cmux SSH" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Claude Code Teams</h3>
<code>cmux claude-teams</code> lance le mode coéquipier de Claude Code en une seule commande. Les coéquipiers apparaissent comme des divisions natives avec des métadonnées dans la barre latérale et des notifications. Pas besoin de tmux.
</td>
<td width="60%">
<img src="./docs/assets/claude-code-teams.png" alt="Claude Code Teams" width="100%" />
</td>
</tr>
</table>

- **Import navigateur** — Importez les cookies, l'historique et les sessions depuis Chrome, Firefox, Arc et plus de 20 navigateurs pour que les panneaux navigateur démarrent authentifiés
- **Commandes personnalisées** — Définissez des actions spécifiques au projet dans [`cmux.json`](https://cmux.com/docs/custom-commands) qui se lancent depuis la palette de commandes
- **Scriptable** — CLI et API socket pour créer des espaces de travail, diviser des panneaux, envoyer des frappes clavier et automatiser le navigateur
- **Application macOS native** — Construite avec Swift et AppKit, pas Electron. Démarrage rapide, faible consommation mémoire.
- **Compatible Ghostty** — Lit votre fichier `~/.config/ghostty/config` existant pour les thèmes, polices et couleurs
- **Accélération GPU** — Propulsé par libghostty pour un rendu fluide
- **Raccourcis clavier** — [Raccourcis étendus](https://cmux.com/docs/keyboard-shortcuts) pour les espaces de travail, les divisions, le navigateur et plus encore
- **Open source** — Gratuit et sous licence GPL

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
| ⌥ ⌘ E | Modifier la description de l'espace de travail |
| ⌘ B | Basculer la barre latérale |
| ⌥ ⌘ B | Basculer la barre latérale droite |
| ⌘ ⇧ E | Basculer le focus de la barre latérale droite |

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
Les raccourcis de navigation de la palette de commandes, y compris ⌃ P, sont également personnalisables et peuvent être effacés pour que la frappe atteigne le terminal actif.

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
| ⌥ ⌘ U | Basculer l'état non lu de l'élément actuel |
| ⌃ ⌘ U | Marquer l'élément actuel comme la plus ancienne non lue et passer à la suivante plus récente non lue |

### Recherche

| Raccourci | Action |
|----------|--------|
| ⌘ F | Rechercher |
| ⌘ ⇧ F | Rechercher dans le répertoire |
| ⌘ G / ⌥ ⌘ G | Résultat suivant / précédent |
| ⌥ ⌘ ⇧ F | Masquer la barre de recherche |
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
| ⌘ ⇧ O | Rouvrir la session précédente |
| ⌘ , | Paramètres |
| ⌘ ⇧ , | Recharger la configuration |
| ⌘ Q | Quitter |

## Builds Nightly

[Télécharger cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY est une application séparée avec son propre identifiant de bundle, elle fonctionne donc en parallèle de la version stable. Construite automatiquement à partir du dernier commit `main` et mise à jour automatiquement via son propre flux Sparkle.

Signalez les bugs nightly sur [GitHub Issues](https://github.com/manaflow-ai/cmux/issues) ou dans [#nightly-bugs sur Discord](https://discord.gg/xsgFEVrWCZ).

## Restauration de session

À la fermeture, cmux enregistre la session en cours. Au relancement, cmux restaure
l'état géré par l'application :
- Disposition des fenêtres/espaces de travail/panneaux
- Répertoires de travail
- Historique de défilement du terminal (au mieux)
- URL du navigateur et historique de navigation

cmux ne crée pas de point de contrôle pour n'importe quel processus actif. tmux, vim, les shells et
les applications de terminal non prises en charge se rouvrent comme des terminaux normaux.

Les sessions d'agents prises en charge peuvent reprendre lorsque les hooks ont enregistré un ID
de session natif. Installez les hooks après avoir installé le CLI de l'agent pour que son
binaire soit dans le `PATH` :

```bash
cmux hooks setup
cmux hooks setup codex
cmux hooks setup --agent opencode
```

`cmux hooks setup` installe les agents pris en charge qu'il trouve et affiche un résumé
des agents ignorés. Les intégrations de reprise prises en charge incluent Claude Code, Codex,
Grok, OpenCode, Pi, Amp, Cursor CLI, Gemini, Rovo Dev, Copilot, CodeBuddy,
Factory et Qoder. Claude Code est géré par le wrapper Claude de cmux lorsque l'intégration
Claude est activée dans les Paramètres.

Les utilisateurs avancés et les intégrations peuvent associer une commande de reprise personnalisée à la
surface de terminal active. C'est utile pour les outils qui ont leur propre état durable, comme
les sessions tmux ou les CLI d'agents personnalisés :

```bash
cmux surface resume set --kind tmux --checkpoint work --shell "tmux attach -t work"
cmux surface resume show --json
cmux surface resume clear --checkpoint work
```

Cette association reste liée à la surface cmux. Les associations créées par le CLI public ou
le socket sont conservées pour inspection et reprise manuelle, sauf si vous approuvez un préfixe
de commande signé pour une reprise automatique. Les préfixes approuvés sont également liés au
répertoire de travail et aux valeurs exactes de l'environnement, lorsqu'elles sont présentes. Examinez ou
modifiez les approbations dans **Paramètres > Terminal > Commandes de reprise**. cmux exécute
automatiquement seulement les associations de reprise qu'il marque comme fiables, comme les associations
tmux détectées depuis des processus actifs ou les préfixes approuvés par l'utilisateur. Les clés
d'environnement sensibles, comme les jetons, mots de passe, secrets et clés API, sont supprimées avant
l'enregistrement d'une association de reprise.

Pour garder les terminaux d'agents restaurés inactifs au lieu d'exécuter automatiquement leurs commandes de reprise,
désactivez **Paramètres > Terminal > Reprendre les sessions d'agents à la réouverture** ou définissez ceci dans
`~/.config/cmux/cmux.json` :

```json
{
  "terminal": {
    "autoResumeAgentSessions": false
  }
}
```

Cela désactive uniquement les commandes de reprise automatique des agents. cmux continue de restaurer la disposition enregistrée,
les répertoires de travail, l'historique de défilement et l'historique du navigateur.

Si vous devez réappliquer manuellement le dernier instantané enregistré, utilisez :
- `Fichier > Rouvrir la session précédente`
- `⌘ ⇧ O`
- `cmux restore-session`

En interne, cmux écrit un instantané versionné dans
`~/Library/Application Support/cmux/` et les hooks d'agents écrivent les correspondances de session
dans `~/.cmuxterm/`. À la restauration, cmux reconstruit d'abord la disposition, puis exécute la
commande de reprise native de l'agent pris en charge lorsque la reprise automatique d'agents est activée.

Lisez le guide complet sur <https://cmux.com/docs/session-restore>.

## FAQ

### Quel est le rapport entre cmux et Ghostty ?

cmux n'est pas un fork de Ghostty. Il utilise [libghostty](https://github.com/ghostty-org/ghostty) comme bibliothèque pour le rendu du terminal, de la même manière que les applications utilisent WebKit pour les vues web. Ghostty est un terminal autonome ; cmux est une application différente construite par-dessus son moteur de rendu.

### Quelles plateformes sont prises en charge ?

macOS uniquement, pour l'instant. cmux est une application native Swift + AppKit.

### Y a-t-il une application iOS ?

Oui, en bêta. Associez votre iPhone à votre Mac depuis la fenêtre Mobile Connect et connectez-vous à vos terminaux depuis votre téléphone, avec transfert optionnel des notifications du terminal. Elle est distribuée sur TestFlight sous le nom cmux BETA. Consultez la [documentation iOS](https://cmux.com/docs/ios).

### Avec quels agents de programmation cmux fonctionne-t-il ?

Avec tous. cmux est un terminal, donc tout agent qui s'exécute dans un terminal fonctionne immédiatement : Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, Goose, Amp, Cline, Cursor Agent, et tout ce que vous pouvez lancer depuis la ligne de commande.

### cmux peut-il orchestrer plusieurs agents et sous-agents ?

Oui. Quand un agent génère des sous-agents ou des coéquipiers, cmux les transforme en panneaux et divisions natifs au lieu de processus cachés en arrière-plan. Il prend en charge [Claude Code teams](https://cmux.com/docs/agent-integrations/claude-code-teams) et l'orchestration multi-modèles [oh-my-opencode](https://cmux.com/docs/agent-integrations/oh-my-opencode), de sorte que chaque agent d'une exécution est visible et contrôlable.

### Puis-je utiliser cmux avec des machines distantes ?

Oui. Ouvrez des espaces de travail via SSH et connectez-vous à des sessions tmux distantes, pour que les agents puissent s'exécuter sur un hôte distant pendant que vous les pilotez depuis cmux. Consultez [SSH et distant](https://cmux.com/docs/ssh).

### Comment fonctionnent les notifications ?

Quand un processus a besoin d'attention, cmux affiche des anneaux de notification autour des panneaux, des badges de non-lus dans la barre latérale, un popover de notifications et une notification de bureau macOS. Celles-ci se déclenchent automatiquement via des séquences d'échappement de terminal standard (OSC 9/99/777), ou vous pouvez les déclencher avec le [CLI cmux](https://cmux.com/docs/notifications#cli-usage) et les [hooks d'agents](https://cmux.com/docs/notifications#integration-examples). Tout agent qui prend en charge les hooks ou OSC fonctionne, y compris Claude Code, Codex, OpenCode et pi.

### cmux est-il programmable ?

Oui. Chaque action est disponible via le CLI cmux et un socket Unix : créer des espaces de travail, ouvrir des panneaux divisés, envoyer de l'entrée, lire le contenu de l'écran, prendre des captures et piloter le navigateur intégré. Consultez la [référence du CLI](https://cmux.com/docs/api) et la documentation [automatisation du navigateur](https://cmux.com/docs/browser-automation).

### Que peut faire le navigateur intégré ?

cmux peut diviser un véritable panneau navigateur à côté de votre terminal, et il est entièrement programmable : naviguer, capturer le DOM, cliquer, taper, exécuter du JavaScript et lire l'activité de la console et du réseau via la même API socket. Les agents l'utilisent pour vérifier leurs propres modifications web sans quitter cmux. Consultez [automatisation du navigateur](https://cmux.com/docs/browser-automation).

### cmux dispose-t-il de skills ?

Oui. Les skills sont des flux de travail réutilisables que vous pouvez donner à n'importe quel agent s'exécutant dans cmux, pour des choses comme le contrôle du CLI, l'automatisation des espaces de travail, les paramètres et les surfaces navigateur. Parcourez la collection ouverte sur [cmux-skills](https://github.com/manaflow-ai/cmux-skills), ou lisez la [documentation des skills](https://cmux.com/docs/skills).

### Puis-je personnaliser les raccourcis clavier ?

Les combinaisons de touches du terminal sont lues depuis votre fichier de configuration Ghostty (`~/.config/ghostty/config`). Les raccourcis spécifiques à cmux (espaces de travail, divisions, navigateur, notifications) peuvent être personnalisés dans les Paramètres. Consultez les [raccourcis par défaut](https://cmux.com/docs/keyboard-shortcuts) pour la liste complète.

### Puis-je personnaliser cmux ?

Oui. Le rendu du terminal utilise votre configuration Ghostty, donc les thèmes, polices, couleurs et curseur sont repris directement. Les paramètres propres à cmux dans `~/.config/cmux/cmux.json` contrôlent la barre latérale, la barre d'onglets, les panneaux divisés et le comportement, et chaque [raccourci clavier](https://cmux.com/docs/keyboard-shortcuts) est modifiable. Consultez [configuration](https://cmux.com/docs/configuration).

### Mes sessions sont-elles enregistrées ?

Oui. cmux restaure vos fenêtres, espaces de travail, panneaux, répertoires de travail et historique de défilement au relancement, et l'état survit à un redémarrage complet de l'ordinateur, pas seulement à la fermeture de l'application. Les sessions d'agents comme Claude Code, Codex et OpenCode reviennent aussi. Consultez [restauration de session](https://cmux.com/docs/session-restore).

### Comment cmux se compare-t-il à tmux ?

tmux est un multiplexeur de terminal qui s'exécute dans n'importe quel terminal. cmux est une application macOS native avec une interface graphique : onglets verticaux, panneaux divisés, un navigateur intégré et une API socket, le tout intégré, sans fichiers de configuration ni touches de préfixe. Cela dit, beaucoup de gens utilisent volontiers cmux avec SSH et tmux ensemble, et cmux peut se connecter nativement à vos sessions tmux distantes ([bêta](https://cmux.com/docs/remote-tmux)).

### cmux est-il gratuit ?

Oui, cmux est gratuit à utiliser. Le code source est disponible sur [GitHub](https://github.com/manaflow-ai/cmux).

### Comment puis-je soutenir cmux ?

cmux est gratuit et open source, et le restera toujours. Si vous voulez soutenir le développement et obtenir un accès anticipé à ce qui arrive, y compris cmux AI, l'application iOS et les Cloud VMs, découvrez [cmux Founders Edition](https://github.com/manaflow-ai/cmux#founders-edition).

### J'ai une demande de fonctionnalité ou j'ai trouvé un bug ?

Nous voulons en entendre parler. Ouvrez une [issue](https://github.com/manaflow-ai/cmux/issues) ou une [pull request](https://github.com/manaflow-ai/cmux/pulls) sur GitHub, ou [écrivez-nous](mailto:founders@manaflow.com?subject=cmux%20feature%20request).

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
- [WhatsApp](https://chat.whatsapp.com/Fblh7FB58lOI2cx6ccdIqY?mode=gi_t)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

<p>
  <strong>WeChat :</strong> scannez le QR code pour rejoindre la communauté.<br />
  <img src="./docs/assets/wechat-community-qr.jpg" alt="QR code WeChat pour rejoindre la communauté cmux" width="240" />
</p>

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

cmux est open source sous [GPL-3.0-or-later](LICENSE).

Si votre organisation ne peut pas se conformer à la GPL, une licence commerciale est disponible. Contactez [founders@manaflow.com](mailto:founders@manaflow.com) pour plus de détails.
