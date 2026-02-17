> Ovaj prijevod je generisan od strane Claude. Ako imate prijedloge za poboljšanje, otvorite PR.

<p align="center">
  <a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.ja.md">日本語</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | Bosanski | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a>
</p>

<h1 align="center">cmux</h1>
<p align="center">macOS terminal baziran na Ghostty sa vertikalnim tabovima i obavještenjima za AI agente za programiranje</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Preuzmi cmux za macOS" width="180" />
  </a>
</p>

<p align="center">
  <img src="./docs/assets/screenshot.png" alt="cmux snimak ekrana" width="900" />
</p>

## Funkcije

- **Vertikalni tabovi** — Bočna traka prikazuje git granu, radni direktorij, portove koji slušaju i tekst posljednjeg obavještenja
- **Prstenovi obavještenja** — Paneli dobijaju plavi prsten, a tabovi se osvjetljavaju kada AI agenti (Claude Code, OpenCode) trebaju vašu pažnju
- **Panel obavještenja** — Pregledajte sva obavještenja na čekanju na jednom mjestu, skočite na najnovije nepročitano
- **Podijeljeni paneli** — Horizontalna i vertikalna podjela
- **Ugrađeni preglednik** — Podijelite preglednik pored terminala sa skriptabilnim API portiranim iz [agent-browser](https://github.com/vercel-labs/agent-browser)
- **Skriptabilan** — CLI i socket API za kreiranje radnih prostora, dijeljenje panela, slanje pritisaka tipki i automatizaciju preglednika
- **Nativna macOS aplikacija** — Izgrađena sa Swift i AppKit, ne Electron. Brzo pokretanje, niska potrošnja memorije.
- **Kompatibilan sa Ghostty** — Čita vašu postojeću konfiguraciju `~/.config/ghostty/config` za teme, fontove i boje
- **GPU-ubrzanje** — Pokreće ga libghostty za glatko renderiranje

## Instalacija

### DMG (preporučeno)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="Preuzmi cmux za macOS" width="180" />
</a>

Otvorite `.dmg` datoteku i prevucite cmux u folder Aplikacije. cmux se automatski ažurira putem Sparkle, tako da trebate preuzeti samo jednom.

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

Za ažuriranje kasnije:

```bash
brew upgrade --cask cmux
```

Pri prvom pokretanju, macOS vas može zamoliti da potvrdite otvaranje aplikacije od identificiranog programera. Kliknite **Otvori** da nastavite.

## Zašto cmux?

Pokrećem mnogo Claude Code i Codex sesija paralelno. Koristio sam Ghostty sa gomilom podijeljenih panela i oslanjao se na nativna macOS obavještenja da znam kada agent treba mene. Ali tijelo obavještenja Claude Code je uvijek samo „Claude is waiting for your input" bez konteksta, a sa dovoljno otvorenih tabova nisam mogao ni pročitati naslove.

Isprobao sam nekoliko orkestratora za kodiranje, ali većina ih je bila Electron/Tauri aplikacije i performanse su me nervirale. Također jednostavno preferiram terminal jer GUI orkestratori vas zaključavaju u svoj radni tok. Zato sam izgradio cmux kao nativnu macOS aplikaciju u Swift/AppKit. Koristi libghostty za renderiranje terminala i čita vašu postojeću Ghostty konfiguraciju za teme, fontove i boje.

Glavni dodaci su bočna traka i sistem obavještenja. Bočna traka ima vertikalne tabove koji prikazuju git granu, radni direktorij, portove koji slušaju i tekst posljednjeg obavještenja za svaki radni prostor. Sistem obavještenja hvata terminalne sekvence (OSC 9/99/777) i ima CLI (`cmux notify`) koji možete povezati sa hookovima agenata za Claude Code, OpenCode itd. Kada agent čeka, njegov panel dobija plavi prsten, a tab se osvjetljava u bočnoj traci, tako da mogu vidjeti koji me treba kroz podjele i tabove. Cmd+Shift+U skače na najnovije nepročitano.

Ugrađeni preglednik ima skriptabilni API portiran iz [agent-browser](https://github.com/vercel-labs/agent-browser). Agenti mogu snimiti stablo pristupačnosti, dobiti reference elemenata, kliknuti, popuniti formulare i evaluirati JS. Možete podijeliti panel preglednika pored terminala i omogućiti Claude Code da direktno komunicira sa vašim razvojnim serverom.

Sve je skriptabilno kroz CLI i socket API — kreiranje radnih prostora/tabova, dijeljenje panela, slanje pritisaka tipki, otvaranje URL-ova u pregledniku.

## Prečice na Tastaturi

### Radni prostori

| Prečica | Akcija |
|----------|--------|
| ⌘ N | Novi radni prostor |
| ⌘ 1–8 | Skoči na radni prostor 1–8 |
| ⌘ 9 | Skoči na posljednji radni prostor |
| ⌃ ⌘ ] | Sljedeći radni prostor |
| ⌃ ⌘ [ | Prethodni radni prostor |
| ⌘ ⇧ W | Zatvori radni prostor |
| ⌘ B | Prikaži/sakrij bočnu traku |

### Površine

| Prečica | Akcija |
|----------|--------|
| ⌘ T | Nova površina |
| ⌘ ⇧ ] | Sljedeća površina |
| ⌘ ⇧ [ | Prethodna površina |
| ⌃ Tab | Sljedeća površina |
| ⌃ ⇧ Tab | Prethodna površina |
| ⌃ 1–8 | Skoči na površinu 1–8 |
| ⌃ 9 | Skoči na posljednju površinu |
| ⌘ W | Zatvori površinu |

### Podijeljeni Paneli

| Prečica | Akcija |
|----------|--------|
| ⌘ D | Podijeli desno |
| ⌘ ⇧ D | Podijeli dolje |
| ⌥ ⌘ ← → ↑ ↓ | Fokusiraj panel po smjeru |
| ⌘ ⇧ H | Trepni fokusiranim panelom |

### Preglednik

| Prečica | Akcija |
|----------|--------|
| ⌘ ⇧ L | Otvori preglednik u podjeli |
| ⌘ L | Fokusiraj adresnu traku |
| ⌘ [ | Nazad |
| ⌘ ] | Naprijed |
| ⌘ R | Ponovo učitaj stranicu |
| ⌥ ⌘ I | Otvori Alate za Programere |

### Obavještenja

| Prečica | Akcija |
|----------|--------|
| ⌘ I | Prikaži panel obavještenja |
| ⌘ ⇧ U | Skoči na posljednje nepročitano |

### Pretraga

| Prečica | Akcija |
|----------|--------|
| ⌘ F | Pretraži |
| ⌘ G / ⌘ ⇧ G | Nađi sljedeći / prethodni |
| ⌘ ⇧ F | Sakrij traku pretrage |
| ⌘ E | Koristi selekciju za pretragu |

### Terminal

| Prečica | Akcija |
|----------|--------|
| ⌘ K | Očisti scrollback |
| ⌘ C | Kopiraj (sa selekcijom) |
| ⌘ V | Zalijepi |
| ⌘ + / ⌘ - | Povećaj / smanji veličinu fonta |
| ⌘ 0 | Resetuj veličinu fonta |

### Prozor

| Prečica | Akcija |
|----------|--------|
| ⌘ ⇧ N | Novi prozor |
| ⌘ , | Postavke |
| ⌘ ⇧ , | Ponovo učitaj konfiguraciju |
| ⌘ Q | Zatvori |

## Licenca

Ovaj projekat je licenciran pod GNU Affero General Public License v3.0 ili novijom (`AGPL-3.0-or-later`).

Pogledajte `LICENSE` za puni tekst.
