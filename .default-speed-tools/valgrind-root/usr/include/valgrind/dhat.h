
/*
   ----------------------------------------------------------------

   Notice that the following BSD-style license applies to this one
   file (dhat.h) only.  The rest of Valgrind is licensed under the
   terms of the GNU General Public License, version 2, unless
   otherwise indicated.  See the COPYING file in the source
   distribution for details.

   ----------------------------------------------------------------

   This file is part of DHAT, a Valgrind tool for profiling the
   heap usage of programs.

   Copyright (C) 2020 Nicholas Nethercote.  All rights reserved.

   Redistribution and use in source and binary forms, with or without
   modification, are permitted provided that the following conditions
   are met:

   1. Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

   2. The origin of this software must not be misrepresented; you must
      not claim that you wrote the original software.  If you use this
      software in a product, an acknowledgment in the product
      documentation would be appreciated but is not required.

   3. Altered source versions must be plainly marked as such, and must
      not be misrepresented as being the original software.

   4. The name of the author may not be used to endorse or promote
      products derived from this software without specific prior written
      permission.

   THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS
   OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
   WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
   ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
   DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
   DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
   GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
   INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
   WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

   ----------------------------------------------------------------

   Notice that the above BSD-style license applies to this one file
   (memcheck.h) only.  The entire rest of Valgrind is licensed under
   the terms of the GNU General Public License, version 2.  See the
   COPYING file in the source distribution for details.

   ----------------------------------------------------------------
*/

#if !defined(VALGRIND_DHAT_H)
#define VALGRIND_DHAT_H

#include "valgrind.h"

typedef
   enum {
      VG_USERREQ__DHAT_AD_HOC_EVENT = VG_USERREQ_TOOL_BASE('D', 'H'),
      VG_USERREQ__DHAT_HISTOGRAM_MEMORY,

      // This is just for DHAT's internal use. Don't use it.
      _VG_USERREQ__DHAT_COPY = VG_USERREQ_TOOL_BASE('D','H') + 256
   } Vg_DHATClientRequest;

// Record an ad hoc event. The meaning of the weight argument will depend on
// what the event represents, which is up to the user. If no meaningful weight
// argument exists, just use 1.
#define DHAT_AD_HOC_EVENT(_qzz_weight) \
    VALGRIND_DO_CLIENT_REQUEST_STMT(VG_USERREQ__DHAT_AD_HOC_EVENT, \
                                    (_qzz_weight), 0, 0, 0, 0)

// for access count histograms of memory larger than 1k
#define DHAT_HISTOGRAM_MEMORY(_qzz_address) \
    VALGRIND_DO_CLIENT_REQUEST_STMT(VG_USERREQ__DHAT_HISTOGRAM_MEMORY, \
                                    (_qzz_address), 0, 0, 0, 0)

#endif

