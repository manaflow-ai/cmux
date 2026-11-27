set -e
if command -v valgrind >/dev/null 2>&1; then
  valgrind --version
  exit 0
fi
mkdir -p "$CI_TOOLS/valgrind-deb" "$CI_TOOLS/bin"
if ! (cd "$CI_TOOLS/valgrind-deb" && apt-get download valgrind); then
  apt_dir="$CI_TOOLS/apt"
  mkdir -p "$apt_dir/lists/partial" "$apt_dir/cache/archives/partial"
  apt_opts=(-o "Dir::State::Lists=$apt_dir/lists" -o "Dir::Cache=$apt_dir/cache" -o Debug::NoLocking=1)
  echo "the host apt index has no valgrind; fetching a job-local index into $apt_dir"
  apt-get "${apt_opts[@]}" -o Acquire::Retries=3 update -qq
  (cd "$CI_TOOLS/valgrind-deb" && apt-get "${apt_opts[@]}" download valgrind)
fi
dpkg -x "$CI_TOOLS"/valgrind-deb/valgrind_*.deb "$CI_TOOLS/valgrind-root"
lib="$(dirname "$(find "$CI_TOOLS/valgrind-root" -name 'callgrind-*-linux' | head -n 1)")"
[ -d "$lib" ] || { echo "the valgrind package holds no callgrind"; exit 1; }
printf '#!/bin/sh\nVALGRIND_LIB=%s exec %s "$@"\n' "$lib" "$CI_TOOLS/valgrind-root/usr/bin/valgrind" > "$CI_TOOLS/bin/valgrind"
chmod +x "$CI_TOOLS/bin/valgrind"
"$CI_TOOLS/bin/valgrind" --version
