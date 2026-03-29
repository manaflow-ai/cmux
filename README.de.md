> Diese Übersetzung wurde von Claude erstellt. Verbesserungsvorschläge sind als PR willkommen.

<h1 align="center">cmux</h1>
<p align="center">Ein Ghostty-basiertes macOS-Terminal mit vertikalen Tabs und Benachrichtigungen für AI-Coding-Agenten</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="cmux für macOS herunterladen" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | Deutsch | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a> | <a href="README.uk.md">Українська</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="cmux Screenshot" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ Demo-Video</a> · <a href="https://cmux.com/blog/zen-of-cmux">The Zen of cmux</a>
</p>

## Funktionen

<table>
<tr>
<td width="40%" valign="middle">
<h3>Benachrichtigungsringe</h3>
Bereiche erhalten einen blauen Ring und Tabs leuchten auf, wenn Coding-Agenten Ihre Aufmerksamkeit benötigen
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="Benachrichtigungsringe" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Benachrichtigungspanel</h3>
Alle ausstehenden Benachrichtigungen auf einen Blick sehen und zur neuesten ungelesenen springen
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="Seitenleisten-Benachrichtigungsabzeichen" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Integrierter Browser</h3>
Teilen Sie einen Browser neben Ihrem Terminal mit einer skriptfähigen API, portiert von <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="Integrierter Browser" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Vertikale + horizontale Tabs</h3>
Die Seitenleiste zeigt Git-Branch, verknüpften PR-Status/Nummer, Arbeitsverzeichnis, lauschende Ports und den neuesten Benachrichtigungstext. Horizontal und vertikal teilen.
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="Vertikale Tabs und geteilte Bereiche" width="100%" />
</td>
</tr>
</table>

- **Skriptfähig** — CLI und Socket-API zum Erstellen von Arbeitsbereichen, Teilen von Bereichen, Senden von Tastenanschlägen und Automatisieren des Browsers
- **Native macOS-App** — Entwickelt mit Swift und AppKit, nicht Electron. Schneller Start, geringer Speicherverbrauch.
- **Ghostty-kompatibel** — Liest Ihre vorhandene `~/.config/ghostty/config` für Themes, Schriftarten und Farben
- **GPU-beschleunigt** — Angetrieben von libghostty für flüssiges Rendering

## Installation

### DMG (empfohlen)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="cmux für macOS herunterladen" width="180" />
</a>

Öffnen Sie die `.dmg`-Datei und ziehen Sie cmux in Ihren Programme-Ordner. cmux aktualisiert sich automatisch über Sparkle, sodass Sie nur einmal herunterladen müssen.

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

Später aktualisieren:

```bash
brew upgrade --cask cmux
```

Beim ersten Start fordert macOS Sie möglicherweise auf, das Öffnen einer App von einem identifizierten Entwickler zu bestätigen. Klicken Sie auf **Öffnen**, um fortzufahren.

## Warum cmux?

Ich führe viele Claude Code- und Codex-Sitzungen parallel aus. Ich habe Ghostty mit einer Menge geteilter Bereiche verwendet und mich auf die nativen macOS-Benachrichtigungen verlassen, um zu wissen, wann ein Agent mich braucht. Aber der Benachrichtigungstext von Claude Code ist immer nur „Claude is waiting for your input" ohne Kontext, und bei genügend offenen Tabs konnte ich nicht einmal mehr die Titel lesen.

Ich habe einige Coding-Orchestratoren ausprobiert, aber die meisten waren Electron/Tauri-Apps und die Performance hat mich gestört. Ich bevorzuge außerdem das Terminal, da GUI-Orchestratoren einen in ihren Workflow einschließen. Also habe ich cmux als native macOS-App in Swift/AppKit gebaut. Es verwendet libghostty für das Terminal-Rendering und liest Ihre vorhandene Ghostty-Konfiguration für Themes, Schriftarten und Farben.

Die wesentlichen Ergänzungen sind die Seitenleiste und das Benachrichtigungssystem. Die Seitenleiste hat vertikale Tabs, die Git-Branch, verknüpften PR-Status/Nummer, Arbeitsverzeichnis, lauschende Ports und den neuesten Benachrichtigungstext für jeden Arbeitsbereich anzeigen. Das Benachrichtigungssystem erkennt Terminal-Sequenzen (OSC 9/99/777) und bietet eine CLI (`cmux notify`), die Sie in Agent-Hooks für Claude Code, OpenCode usw. einbinden können. Wenn ein Agent wartet, bekommt sein Bereich einen blauen Ring und der Tab leuchtet in der Seitenleiste auf, sodass ich über Teilungen und Tabs hinweg erkennen kann, welcher mich braucht. ⌘⇧U springt zur neuesten ungelesenen Benachrichtigung.

Der integrierte Browser hat eine skriptfähige API, portiert von [agent-browser](https://github.com/vercel-labs/agent-browser). Agenten können den Barrierefreiheitsbaum erfassen, Elementreferenzen erhalten, klicken, Formulare ausfüllen und JS ausführen. Sie können einen Browser-Bereich neben Ihrem Terminal teilen und Claude Code direkt mit Ihrem Entwicklungsserver interagieren lassen.

Alles ist über CLI und Socket-API skriptfähig — Arbeitsbereiche/Tabs erstellen, Bereiche teilen, Tastenanschläge senden, URLs im Browser öffnen.

## The Zen of cmux

cmux schreibt Entwicklern nicht vor, wie sie ihre Werkzeuge nutzen sollen. Es ist ein Terminal und Browser mit einer CLI, und der Rest liegt bei Ihnen.

cmux ist ein Grundbaustein, keine fertige Lösung. Es bietet Ihnen ein Terminal, einen Browser, Benachrichtigungen, Arbeitsbereiche, Teilungen, Tabs und eine CLI, um alles zu steuern. cmux zwingt Sie nicht in eine bestimmte Art, Coding-Agenten zu nutzen. Was Sie mit den Grundbausteinen bauen, ist Ihre Sache.

Die besten Entwickler haben schon immer ihre eigenen Werkzeuge gebaut. Niemand hat bisher die beste Art gefunden, mit Agenten zu arbeiten, und die Teams, die geschlossene Produkte bauen, auch nicht. Die Entwickler, die ihren eigenen Codebasen am nächsten sind, werden es zuerst herausfinden.

Geben Sie einer Million Entwickler komponierbare Grundbausteine, und sie werden gemeinsam die effizientesten Workflows schneller finden, als jedes Produktteam es von oben herab entwerfen könnte.

## Dokumentation

Weitere Informationen zur Konfiguration von cmux finden Sie in [unserer Dokumentation](https://cmux.com/docs/getting-started?utm_source=readme).

## Tastenkürzel

### Arbeitsbereiche

| Tastenkürzel | Aktion |
|----------|--------|
| ⌘ N | Neuer Arbeitsbereich |
| ⌘ 1–8 | Zu Arbeitsbereich 1–8 springen |
| ⌘ 9 | Zum letzten Arbeitsbereich springen |
| ⌃ ⌘ ] | Nächster Arbeitsbereich |
| ⌃ ⌘ [ | Vorheriger Arbeitsbereich |
| ⌘ ⇧ W | Arbeitsbereich schließen |
| ⌘ ⇧ R | Arbeitsbereich umbenennen |
| ⌘ B | Seitenleiste umschalten |

### Oberflächen

| Tastenkürzel | Aktion |
|----------|--------|
| ⌘ T | Neue Oberfläche |
| ⌘ ⇧ ] | Nächste Oberfläche |
| ⌘ ⇧ [ | Vorherige Oberfläche |
| ⌃ Tab | Nächste Oberfläche |
| ⌃ ⇧ Tab | Vorherige Oberfläche |
| ⌃ 1–8 | Zu Oberfläche 1–8 springen |
| ⌃ 9 | Zur letzten Oberfläche springen |
| ⌘ W | Oberfläche schließen |

### Geteilte Bereiche

| Tastenkürzel | Aktion |
|----------|--------|
| ⌘ D | Nach rechts teilen |
| ⌘ ⇧ D | Nach unten teilen |
| ⌥ ⌘ ← → ↑ ↓ | Bereich richtungsabhängig fokussieren |
| ⌘ ⇧ H | Fokussierten Bereich aufblitzen |

### Browser

Tastenkürzel für Browser-Entwicklertools folgen den Safari-Standardeinstellungen und sind in `Einstellungen → Tastenkürzel` anpassbar.

| Tastenkürzel | Aktion |
|----------|--------|
| ⌘ ⇧ L | Browser in Teilung öffnen |
| ⌘ L | Adressleiste fokussieren |
| ⌘ [ | Zurück |
| ⌘ ] | Vorwärts |
| ⌘ R | Seite neu laden |
| ⌥ ⌘ I | Entwicklertools umschalten (Safari-Standard) |
| ⌥ ⌘ C | JavaScript-Konsole anzeigen (Safari-Standard) |

### Benachrichtigungen

| Tastenkürzel | Aktion |
|----------|--------|
| ⌘ I | Benachrichtigungspanel anzeigen |
| ⌘ ⇧ U | Zur neuesten ungelesenen springen |

### Suchen

| Tastenkürzel | Aktion |
|----------|--------|
| ⌘ F | Suchen |
| ⌘ G / ⌘ ⇧ G | Nächstes / vorheriges Ergebnis |
| ⌘ ⇧ F | Suchleiste ausblenden |
| ⌘ E | Auswahl für Suche verwenden |

### Terminal

| Tastenkürzel | Aktion |
|----------|--------|
| ⌘ K | Scrollback löschen |
| ⌘ C | Kopieren (mit Auswahl) |
| ⌘ V | Einfügen |
| ⌘ + / ⌘ - | Schriftgröße vergrößern / verkleinern |
| ⌘ 0 | Schriftgröße zurücksetzen |

### Fenster

| Tastenkürzel | Aktion |
|----------|--------|
| ⌘ ⇧ N | Neues Fenster |
| ⌘ , | Einstellungen |
| ⌘ ⇧ , | Konfiguration neu laden |
| ⌘ Q | Beenden |

## Nightly Builds

[cmux NIGHTLY herunterladen](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY ist eine separate App mit eigener Bundle-ID, die neben der stabilen Version läuft. Wird automatisch vom neuesten `main`-Commit gebaut und aktualisiert sich über einen eigenen Sparkle-Feed.

## Sitzungswiederherstellung (aktuelles Verhalten)

Beim Neustart stellt cmux derzeit nur App-Layout und Metadaten wieder her:
- Fenster-/Arbeitsbereich-/Bereichs-Layout
- Arbeitsverzeichnisse
- Terminal-Scrollback (bestmöglich)
- Browser-URL und Navigationsverlauf

cmux stellt **keine** laufenden Prozesse in Terminal-Apps wieder her. Zum Beispiel werden aktive Claude Code-/tmux-/vim-Sitzungen nach einem Neustart noch nicht fortgesetzt.

## Star-Verlauf

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## Mitwirken

Möglichkeiten, sich einzubringen:

- Folgen Sie uns auf X für Updates [@manaflowai](https://x.com/manaflowai), [@lawrencecchen](https://x.com/lawrencecchen) und [@austinywang](https://x.com/austinywang)
- Nehmen Sie an der Diskussion auf [Discord](https://discord.gg/xsgFEVrWCZ) teil
- Erstellen Sie [GitHub Issues](https://github.com/manaflow-ai/cmux/issues) und beteiligen Sie sich an [Diskussionen](https://github.com/manaflow-ai/cmux/discussions)
- Lassen Sie uns wissen, was Sie mit cmux bauen

## Community

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

## Founder's Edition

cmux ist kostenlos, Open Source und wird es immer sein. Wenn Sie die Entwicklung unterstützen und frühen Zugang zu kommenden Funktionen erhalten möchten:

**[Founder's Edition erhalten](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **Priorisierte Feature-Requests/Bugfixes**
- **Früher Zugang: cmux AI, das Ihnen Kontext zu jedem Arbeitsbereich, Tab und Panel gibt**
- **Früher Zugang: iOS-App mit zwischen Desktop und Telefon synchronisierten Terminals**
- **Früher Zugang: Cloud-VMs**
- **Früher Zugang: Sprachmodus**
- **Meine persönliche iMessage/WhatsApp**

## Lizenz

cmux ist Open Source unter [AGPL-3.0-or-later](LICENSE).

Wenn Ihre Organisation AGPL nicht einhalten kann, ist eine kommerzielle Lizenz verfügbar. Kontaktieren Sie [founders@manaflow.com](mailto:founders@manaflow.com) für Details.
