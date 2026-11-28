#ifndef CMUX_NEXT_LINK_ORDER_H_
#define CMUX_NEXT_LINK_ORDER_H_
// The link order probe (scripts/measure/link-order.sh): in a build made with CMUX_LINK_ORDER_PROBE=1
// (scripts/reload.sh), every Swift, C and Objective-C function calls the coverage guard below the first
// time it runs, and the probe writes those functions' addresses, in that order, to the file
// $CMUX_LINK_ORDER_OUT names. scripts/cmux-next/link-order.py turns the addresses into the symbol list
// Packages/macOS/CmuxNext/LinkOrder/CmuxNextApp.order, which the Release link of CmuxNextApp reads
// (-order_file): the code a launch runs sits together, in the order it runs, so a cold launch
// pages in fewer pages of the framework. Every other build compiles this target to nothing.
#endif
