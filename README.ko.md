> 이 문서는 Claude가 번역했어요. 개선할 부분이 있다면 PR을 보내주세요.

<p align="center"><a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | 한국어 | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.ja.md">日本語</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a></p>

<h1 align="center">cmux</h1>
<p align="center">세로 탭과 알림을 지원하는 AI 코딩 에이전트용 Ghostty 기반 macOS 터미널</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="macOS용 cmux 다운로드" width="180" />
  </a>
</p>

<p align="center">
  <img src="./docs/assets/screenshot.png" alt="cmux 스크린샷" width="900" />
</p>

## 기능

- **세로 탭** — 사이드바에서 git 브랜치, 작업 디렉토리, 수신 포트, 최근 알림 텍스트를 한눈에 볼 수 있어요.
- **알림 링** — AI 에이전트(Claude Code, OpenCode)가 입력을 기다리면 패널에 파란색 링이 뜨고 탭이 강조돼요.
- **알림 패널** — 대기 중인 알림을 한곳에서 확인하고, 가장 최근 읽지 않은 알림으로 바로 이동할 수 있어요.
- **분할 패널** — 수평·수직 분할을 지원해요.
- **내장 브라우저** — [agent-browser](https://github.com/vercel-labs/agent-browser)에서 포팅된 스크립팅 API를 갖춘 브라우저를 터미널 옆에 띄울 수 있어요.
- **스크립팅** — CLI와 socket API로 워크스페이스 생성, 패널 분할, 키 입력 전송, 브라우저 자동화가 가능해요.
- **네이티브 macOS 앱** — Electron이 아닌 Swift와 AppKit으로 만들었어요. 빠르게 실행되고 메모리도 적게 써요.
- **Ghostty 호환** — 기존 `~/.config/ghostty/config`에서 테마, 글꼴, 색상 설정을 그대로 읽어와요.
- **GPU 가속** — libghostty 기반이라 렌더링이 부드러워요.

## 설치하기

### DMG (권장)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="macOS용 cmux 다운로드" width="180" />
</a>

`.dmg` 파일을 열고 cmux를 응용 프로그램 폴더로 드래그하면 돼요. Sparkle을 통해 자동 업데이트되니 한 번만 다운로드하면 돼요.

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

나중에 업데이트하려면 아래 명령어를 실행해주세요:

```bash
brew upgrade --cask cmux
```

처음 실행할 때 macOS에서 개발자 확인 팝업이 뜰 수 있어요. **열기**를 클릭하면 돼요.

## 왜 cmux를 만들었나요?

저는 Claude Code와 Codex 세션을 여러 개 동시에 돌려요. 예전에는 Ghostty에서 분할 패널을 여러 개 열어놓고, 에이전트가 입력을 기다릴 때 macOS 기본 알림에 의존했어요. 그런데 Claude Code 알림은 항상 "Claude is waiting for your input"이라는 아무 맥락 없이 똑같은 메시지뿐이었고, 탭이 많아지면 제목조차 읽을 수가 없었어요.

여러 코딩 오케스트레이터를 써봤는데, 대부분 Electron/Tauri 앱이라 성능이 별로였어요. GUI 오케스트레이터는 특정 워크플로우에 갇히게 돼서 터미널이 더 낫다고 생각했고요. 그래서 Swift/AppKit으로 네이티브 macOS 앱인 cmux를 직접 만들었어요. 터미널 렌더링에는 libghostty를 쓰고, 기존 Ghostty 설정에서 테마, 글꼴, 색상을 그대로 가져와요.

핵심은 사이드바와 알림 시스템이에요. 사이드바에는 각 워크스페이스의 git 브랜치, 작업 디렉토리, 수신 포트, 최근 알림 텍스트를 보여주는 세로 탭이 있어요. 알림 시스템은 터미널 시퀀스(OSC 9/99/777)를 감지하고, Claude Code나 OpenCode 같은 에이전트 훅에 연결할 수 있는 CLI(`cmux notify`)를 제공해요. 에이전트가 대기 중이면 해당 패널에 파란색 링이 뜨고 사이드바 탭이 강조되니까, 여러 패널과 탭 중에서 어디서 입력을 기다리는지 바로 알 수 있어요. ⌘⇧U를 누르면 가장 최근 읽지 않은 알림으로 이동해요.

내장 브라우저는 [agent-browser](https://github.com/vercel-labs/agent-browser)에서 포팅한 스크립팅 API를 제공해요. 에이전트가 접근성 트리 스냅샷을 가져오고, 요소를 참조·클릭하고, 양식을 채우고, JS를 실행할 수 있어요. 터미널 옆에 브라우저 패널을 띄워서 Claude Code가 개발 서버와 직접 상호작용하게 할 수 있어요.

CLI와 socket API로 모든 걸 자동화할 수 있어요 — 워크스페이스/탭 생성, 패널 분할, 키 입력 전송, 브라우저에서 URL 열기까지요.

## 키보드 단축키

### 워크스페이스

| 단축키 | 동작 |
|----------|--------|
| ⌘ N | 새 워크스페이스 |
| ⌘ 1–8 | 워크스페이스 1–8로 이동 |
| ⌘ 9 | 마지막 워크스페이스로 이동 |
| ⌃ ⌘ ] | 다음 워크스페이스 |
| ⌃ ⌘ [ | 이전 워크스페이스 |
| ⌘ ⇧ W | 워크스페이스 닫기 |
| ⌘ B | 사이드바 토글 |

### 서피스

| 단축키 | 동작 |
|----------|--------|
| ⌘ T | 새 서피스 |
| ⌘ ⇧ ] | 다음 서피스 |
| ⌘ ⇧ [ | 이전 서피스 |
| ⌃ Tab | 다음 서피스 |
| ⌃ ⇧ Tab | 이전 서피스 |
| ⌃ 1–8 | 서피스 1–8로 이동 |
| ⌃ 9 | 마지막 서피스로 이동 |
| ⌘ W | 서피스 닫기 |

### 분할 패널

| 단축키 | 동작 |
|----------|--------|
| ⌘ D | 오른쪽으로 분할 |
| ⌘ ⇧ D | 아래로 분할 |
| ⌥ ⌘ ← → ↑ ↓ | 방향키로 패널 포커스 이동 |
| ⌘ ⇧ H | 현재 패널 깜빡임 |

### 브라우저

| 단축키 | 동작 |
|----------|--------|
| ⌘ ⇧ L | 분할 패널로 브라우저 열기 |
| ⌘ L | 주소창 포커스 |
| ⌘ [ | 뒤로 |
| ⌘ ] | 앞으로 |
| ⌘ R | 페이지 새로고침 |
| ⌥ ⌘ I | 개발자 도구 열기 |

### 알림

| 단축키 | 동작 |
|----------|--------|
| ⌘ I | 알림 패널 표시 |
| ⌘ ⇧ U | 최근 읽지 않은 알림으로 이동 |

### 찾기

| 단축키 | 동작 |
|----------|--------|
| ⌘ F | 찾기 |
| ⌘ G / ⌘ ⇧ G | 다음 찾기 / 이전 찾기 |
| ⌘ ⇧ F | 찾기 바 숨기기 |
| ⌘ E | 선택한 텍스트로 찾기 |

### 터미널

| 단축키 | 동작 |
|----------|--------|
| ⌘ K | 스크롤백 지우기 |
| ⌘ C | 복사 (선택 시) |
| ⌘ V | 붙여넣기 |
| ⌘ + / ⌘ - | 글꼴 크기 확대 / 축소 |
| ⌘ 0 | 글꼴 크기 초기화 |

### 창

| 단축키 | 동작 |
|----------|--------|
| ⌘ ⇧ N | 새 창 |
| ⌘ , | 설정 |
| ⌘ ⇧ , | 설정 다시 불러오기 |
| ⌘ Q | 종료 |

## 라이선스

이 프로젝트는 GNU Affero General Public License v3.0 이상(`AGPL-3.0-or-later`)으로 배포돼요.

자세한 내용은 `LICENSE` 파일을 확인해주세요.
