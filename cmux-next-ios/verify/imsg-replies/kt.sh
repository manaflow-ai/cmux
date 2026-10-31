# Types lowercase words and spaces by tapping the software keyboard
# (iPhone 17 Pro Max, English QWERTY, points); HID typing hides the keyboard.
# Source after pair.sh. usage: kt <udid> "text"; kret <udid> taps return.
keyxy() {
  case $1 in
    q) echo "25 682";; w) echo "68 682";; e) echo "111 682";; r) echo "154 682";; t) echo "198 682";;
    y) echo "241 682";; u) echo "284 682";; i) echo "328 682";; o) echo "371 682";; p) echo "414 682";;
    a) echo "46 739";; s) echo "89 739";; d) echo "133 739";; f) echo "176 739";; g) echo "219 739";;
    h) echo "263 739";; j) echo "306 739";; k) echo "349 739";; l) echo "392 739";;
    z) echo "89 795";; x) echo "133 795";; c) echo "176 795";; v) echo "219 795";; b) echo "263 795";;
    n) echo "306 795";; m) echo "349 795";; " ") echo "220 851";;
  esac
}
kt() {
  local u=$1 text=$2 n c xy
  local f=$(mktemp)
  for ((n=0; n<${#text}; n++)); do
    c=${text:n:1}; xy=$(keyxy "$c"); [ -z "$xy" ] && continue
    echo "tap -x ${xy% *} -y ${xy#* }" >> $f; echo "sleep 0.05" >> $f
  done
  $A batch --udid "$u" --file $f >/dev/null; rm -f $f
}
kret() { $A tap -x 382 -y 851 --udid "$1" >/dev/null; }
