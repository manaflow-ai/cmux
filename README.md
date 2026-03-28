<h1 align="center">cmux <sup>patched</sup></h1>
<p align="center">좀비 프로세스 버그를 수정한 cmux 포크 — AI 코딩 에이전트를 위한 macOS 터미널</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux">
    <img src="https://img.shields.io/badge/upstream-manaflow--ai%2Fcmux-blue" alt="Upstream" />
  </a>
  <a href="https://github.com/manaflow-ai/cmux/pull/2255">
    <img src="https://img.shields.io/badge/PR-%232255-green" alt="PR #2255" />
  </a>
  <a href="https://github.com/manaflow-ai/cmux/issues/2248">
    <img src="https://img.shields.io/badge/issue-%232248-red" alt="Issue #2248" />
  </a>
</p>

---

## 왜 이 포크가 필요한가?

원본 cmux에서 **PreToolUse 훅이 `async:true`로 실행**되면서, Claude Code가 자식 프로세스를 정리(reap)하지 않아 **좀비 프로세스가 무한 누적**됩니다.

```
                    원본 cmux의 문제
                    ═══════════════

Claude Code ──async:true──▶ cmux claude-hook pre-tool-use
                            │
                            ├─ readDataToEndOfFile() ← stdin EOF 무한 대기
                            ├─ Claude Code는 stdin을 닫지 않음 (async = fire-and-forget)
                            └─ 프로세스가 영원히 살아있음 → 좀비

시간이 지나면...

  좀비 프로세스:     945개+
  열린 파일 디스크립터: 53,833개
  IOSurface GPU 버퍼: 고갈
  WindowServer:      응답 없음 (40초 타임아웃)
  결과:              ⚡ 커널 패닉 → 시스템 강제 재시작
```

## 수정 내용

```
                    수정된 cmux (이 포크)
                    ════════════════════

Claude Code ──sync──▶ cmux claude-hook pre-tool-use
                      │
                      ├─ readStdinWithoutBlocking()
                      │   ├─ stdin을 O_NONBLOCK으로 설정
                      │   ├─ 10ms 간격으로 데이터 폴링
                      │   ├─ 64KB+ 큰 페이로드도 청크 누적으로 처리
                      │   └─ 최대 500ms 후 자동 종료
                      │
                      ├─ 작업 완료 → print("OK")
                      └─ 프로세스 정상 종료 ✓

  좀비 프로세스:     0개 ✓
  시스템 안정성:     정상 ✓
```

## 변경된 파일

| 파일 | 원본 | 이 포크 |
|------|:----:|:-------:|
| `Resources/bin/claude` | `async:true` | **sync** (좀비 근본 원인 제거) |
| `CLI/cmux.swift` | `readDataToEndOfFile()` 블로킹 | **`readStdinWithoutBlocking()`** 논블로킹 루프 |
| `tests/test_claude_wrapper_hooks.py` | async 있는지 검증 | async **없는지** 검증 + 전체 matcher flatten |
| `GhosttyTabs.xcodeproj` | 기본 링커 설정 | vendor/lib 종속 라이브러리 링크 (로컬 빌드 가능) |
| `build/` | 없음 | **빌드된 Debug 앱 포함** (arm64) |

## 빠른 시작

### 방법 1: 빌드된 앱 바로 사용

```bash
git clone https://github.com/scokeepa/cmux.git
cd cmux && git checkout fix/zombie-hook-processes

# macOS 보안 경고 해제 후 실행
xattr -rd com.apple.quarantine "build/cmux DEV fix-zombie.app"
open "build/cmux DEV fix-zombie.app"
```

### 방법 2: wrapper만 교체 (기존 cmux 유지)

가장 간단하고 안전한 방법입니다. 기존 설치된 cmux의 bash wrapper만 교체합니다.

```bash
git clone https://github.com/scokeepa/cmux.git
cd cmux && git checkout fix/zombie-hook-processes

# 원본 백업 후 교체
sudo cp /Applications/cmux.app/Contents/Resources/bin/claude \
        /Applications/cmux.app/Contents/Resources/bin/claude.bak
sudo cp Resources/bin/claude \
        /Applications/cmux.app/Contents/Resources/bin/claude

# cmux 재시작
```

### 방법 3: 소스에서 빌드

```bash
git clone https://github.com/scokeepa/cmux.git
cd cmux && git checkout fix/zombie-hook-processes

# 의존성 설치
brew install zig freetype oniguruma

# GhosttyKit 빌드 + 앱 빌드
./scripts/setup.sh
./scripts/reload.sh --tag my-build --launch
```

## 응급 조치 (좀비가 이미 쌓인 경우)

```bash
# 좀비 프로세스 즉시 정리
pkill -f "cmux claude-hook pre-tool-use"

# 현재 좀비 수 확인
ps aux | grep "cmux claude-hook" | grep -v grep | wc -l
```

## 원본과의 관계

- **Upstream**: [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux)
- **이슈**: [#2248](https://github.com/manaflow-ai/cmux/issues/2248) — 좀비 프로세스 누적 버그 리포트
- **PR**: [#2255](https://github.com/manaflow-ai/cmux/pull/2255) — 이 수정사항의 PR (리뷰 피드백 반영 완료)
- **라이선스**: AGPL-3.0-or-later (원본과 동일)

원본에 수정이 머지되면 이 포크는 더 이상 필요하지 않습니다.

## 원본 cmux 기능

이 포크는 원본 cmux의 모든 기능을 그대로 포함합니다.

- 세로 탭 + 알림 링 (AI 에이전트 입력 대기 시각화)
- Ghostty 기반 GPU 가속 터미널
- Claude Code, Codex, Gemini CLI 등 지원
- 분할 패널, 브라우저 패널, 상태 표시줄
- 자세한 내용: [원본 README](https://github.com/manaflow-ai/cmux/blob/main/README.md)
